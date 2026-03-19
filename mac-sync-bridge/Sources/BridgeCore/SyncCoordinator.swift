import BridgeModels
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence

public actor SyncCoordinator {
    private let dependencies: SyncCoordinatorDependencies

    public init(dependencies: SyncCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    public func runSync(direction: SyncDirection = .bidirectional) async throws -> SyncRunReport {
        let startedAt = dependencies.dateProvider.now()

        let checkpoint = try await dependencies.bridgeStore.loadCheckpoint()
        let mappings = try await dependencies.bridgeStore.loadMappings()
        let reminders = try await dependencies.reminderStore.fetchReminders()

        let pulled = try await dependencies.backendClient.pullChanges(
            request: PullChangesRequest(cursor: checkpoint.backendCursor)
        )

        let plan = buildPlan(
            direction: direction,
            reminders: reminders,
            backendChanges: pulled.changes,
            mappings: mappings
        )

        try await applyLocalChanges(plan.localUpserts, deletes: plan.localDeletes)

        let pushResponse: PushChangesResponse
        if direction == .pull || plan.remoteMutations.isEmpty {
            pushResponse = PushChangesResponse(accepted: [])
        } else {
            pushResponse = try await dependencies.backendClient.pushChanges(
                request: PushChangesRequest(changes: plan.remoteMutations)
            )
        }

        try await persistPushResults(pushResponse.accepted, reminders: reminders)

        let ackIDs = Array(Set(plan.ackTaskIDs + pushResponse.accepted.map(\.task.id)))
        if !ackIDs.isEmpty {
            try await dependencies.backendClient.ackChanges(
                request: AckRequest(taskIDs: ackIDs, cursor: pulled.nextCursor)
            )
        }

        let finishedAt = dependencies.dateProvider.now()
        let nextCheckpoint = SyncCheckpoint(
            backendCursor: pulled.nextCursor ?? checkpoint.backendCursor,
            lastSuccessfulSyncAt: finishedAt,
            lastSuccessfulPullAt: pulled.changes.isEmpty ? checkpoint.lastSuccessfulPullAt : finishedAt,
            lastSuccessfulPushAt: pushResponse.accepted.isEmpty ? checkpoint.lastSuccessfulPushAt : finishedAt,
            lastSuccessfulAckAt: ackIDs.isEmpty ? checkpoint.lastSuccessfulAckAt : finishedAt,
            lastAppleScanStartedAt: startedAt,
            lastSyncStatus: "success"
        )
        try await dependencies.bridgeStore.saveCheckpoint(nextCheckpoint)

        let queuedRetryCount = try await queueRejectedMutations(pushResponse.rejectedReminderIDs, from: plan.remoteMutations)

        return SyncRunReport(
            startedAt: startedAt,
            finishedAt: finishedAt,
            pulledCount: pulled.changes.count,
            pushedCount: pushResponse.accepted.count,
            ackedCount: ackIDs.count,
            conflictCount: plan.conflicts.count,
            queuedRetryCount: queuedRetryCount
        )
    }

    public func buildPlan(
        direction: SyncDirection,
        reminders: [ReminderRecord],
        backendChanges: [BackendTaskRecord],
        mappings: [ReminderTaskMapping]
    ) -> SyncPlan {
        let mappingByReminderID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.reminderID, $0) })
        let mappingByTaskID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.taskID, $0) })
        let reminderByID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })

        var plan = SyncPlan()

        if direction != .push {
            let pullPlan = dependencies.pullPlanner.makePullPlan(
                context: PullPlanningContext(
                    backendChanges: backendChanges,
                    reminderByID: reminderByID,
                    mappingByTaskID: mappingByTaskID
                ),
                conflictResolver: dependencies.conflictResolver
            )
            plan.localUpserts.append(contentsOf: pullPlan.localUpserts)
            plan.localDeletes.append(contentsOf: pullPlan.localDeletes)
            plan.remoteMutations.append(contentsOf: pullPlan.remoteMutations)
            plan.ackTaskIDs.append(contentsOf: pullPlan.ackTaskIDs)
            plan.conflicts.append(contentsOf: pullPlan.conflicts)
        }

        if direction != .pull {
            plan.remoteMutations.append(contentsOf: dependencies.pushPlanner.makePushMutations(
                context: PushPlanningContext(
                    reminders: reminders,
                    mappingByReminderID: mappingByReminderID
                )
            ))
        }

        return SyncPlan(
            localUpserts: plan.localUpserts,
            localDeletes: plan.localDeletes,
            remoteMutations: deduplicatingRemoteMutations(plan.remoteMutations),
            ackTaskIDs: Array(Set(plan.ackTaskIDs)),
            conflicts: plan.conflicts
        )
    }

    private func deduplicatingRemoteMutations(_ mutations: [PushTaskMutation]) -> [PushTaskMutation] {
        var seen = Set<String>()
        var ordered: [PushTaskMutation] = []

        for mutation in mutations.reversed() {
            let key = mutation.taskID ?? "reminder:\(mutation.reminderID)"
            if seen.insert(key).inserted {
                ordered.append(mutation)
            }
        }

        return ordered.reversed()
    }

    private func applyLocalChanges(_ reminders: [ReminderRecord], deletes: [ReminderRecord]) async throws {
        guard !reminders.isEmpty || !deletes.isEmpty else { return }
        if !reminders.isEmpty {
            try await dependencies.reminderStore.upsert(reminders: reminders)
        }
        if !deletes.isEmpty {
            try await dependencies.reminderStore.delete(reminders: deletes)
        }
    }

    private func persistPushResults(_ accepted: [PushTaskResult], reminders: [ReminderRecord]) async throws {
        let reminderByID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let now = dependencies.dateProvider.now()
        let mappings = accepted.compactMap { result -> ReminderTaskMapping? in
            guard let reminder = reminderByID[result.reminderID] else { return nil }
            return ReminderTaskMapping(
                reminderID: result.reminderID,
                taskID: result.task.id,
                reminderExternalIdentifier: reminder.externalIdentifier,
                reminderListIdentifier: reminder.listIdentifier,
                reminderFingerprint: reminder.fingerprint,
                backendVersionToken: result.task.versionToken,
                syncState: result.task.state,
                syncedAt: now
            )
        }
        if !mappings.isEmpty {
            try await dependencies.bridgeStore.saveMappings(mappings)
        }
    }

    private func queueRejectedMutations(_ rejectedReminderIDs: [String], from mutations: [PushTaskMutation]) async throws -> Int {
        guard !rejectedReminderIDs.isEmpty else { return 0 }

        let now = dependencies.dateProvider.now()
        let rejectedSet = Set(rejectedReminderIDs)
        let operations = mutations.compactMap { mutation -> PendingOperation? in
            guard rejectedSet.contains(mutation.reminderID) else { return nil }
            let payload = try? JSONEncoder().encode(mutation)
            return PendingOperation(
                kind: mutation.state == .deleted ? .deleteRemoteTask : .updateRemoteTask,
                entityID: mutation.reminderID,
                payload: payload,
                status: .retrying,
                lastErrorMessage: "push_rejected",
                attemptCount: 1,
                nextRetryAt: dependencies.retryScheduler.nextRetryDate(for: 1, from: now),
                createdAt: now,
                updatedAt: now
            )
        }

        if !operations.isEmpty {
            try await dependencies.bridgeStore.enqueuePendingOperations(operations)
        }
        return operations.count
    }
}
