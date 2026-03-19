import BridgeModels
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence

public actor SyncCoordinator {
    private let dependencies: SyncCoordinatorDependencies

    public struct SyncDebugSnapshot: Sendable {
        public let checkpoint: SyncCheckpoint
        public let pulledCount: Int
        public let plannedPushMutationsCount: Int
        public let plannedPushMutationSummaries: [String]
        public let pushRequestTasksCount: Int
        public let pushRequestTaskSummaries: [String]
        public let pushResponseAcceptedCount: Int
        public let pushResponseAcceptedSummaries: [String]
        public let pushResponseItemsCount: Int
        public let pushResponseItemSummaries: [String]
        public let ackItemsCount: Int
        public let ackItemSummaries: [String]
        public let report: SyncRunReport
    }

    public init(dependencies: SyncCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    public func runSync(direction: SyncDirection = .bidirectional) async throws -> SyncRunReport {
        try await runSyncWithDebug(direction: direction).report
    }

    public func runSyncWithDebug(direction: SyncDirection = .bidirectional) async throws -> SyncDebugSnapshot {
        let startedAt = dependencies.dateProvider.now()

        let checkpoint = try await dependencies.bridgeStore.loadCheckpoint()
        let mappings = try await dependencies.bridgeStore.loadMappings()
        let pending = try await dependencies.bridgeStore.loadPendingOperations()
        let pendingResult = try await consumePendingOperations(pending, now: startedAt)
        let reminders = try await dependencies.reminderStore.fetchReminders()

        let pulled = try await dependencies.backendClient.pullChanges(
            request: PullChangesRequest(
                bridgeID: dependencies.bridgeID,
                cursor: checkpoint.lastPullCursor ?? checkpoint.backendCursor
            )
        )

        let plan = buildPlan(
            direction: direction,
            reminders: reminders,
            backendChanges: pulled.changes,
            mappings: mappings
        )

        try await applyLocalChanges(plan.localUpserts, deletes: plan.localDeletes)

        let pushRequestTasks: [PushTaskVersion]
        let pushResponse: PushChangesResponse
        if direction == .pull {
            pushRequestTasks = []
            pushResponse = PushChangesResponse(accepted: [], items: [])
        } else {
            pushRequestTasks = buildPushTaskVersions(from: plan.remoteMutations)
            pushResponse = try await dependencies.backendClient.pushChanges(
                request: PushChangesRequest(
                    bridgeID: dependencies.bridgeID,
                    cursor: checkpoint.lastPushCursor,
                    tasks: pushRequestTasks
                )
            )
        }

        try await persistPushResults(pushResponse.accepted, reminders: reminders)

        let ackItems = buildAckItems(
            taskIDs: Array(Set(plan.ackTaskIDs + pushResponse.accepted.map(\.task.id))),
            acceptedPushes: pushResponse.accepted,
            remoteItems: pushResponse.items,
            reminders: reminders
        )
        if !ackItems.isEmpty {
            try await dependencies.backendClient.ackChanges(
                request: AckRequest(bridgeID: dependencies.bridgeID, acknowledgements: ackItems)
            )
        }

        let finishedAt = dependencies.dateProvider.now()
        let acceptedChangeIDs = pushResponse.items.compactMap(\.changeID)
        let ackedChangeIDs = ackItems.compactMap(\.changeID)
        let nextCheckpoint = SyncCheckpoint(
            backendCursor: pulled.backendCursor ?? pulled.nextCursor ?? checkpoint.backendCursor,
            lastPullCursor: pulled.nextCursor ?? checkpoint.lastPullCursor,
            lastPushCursor: pushResponse.nextCursor ?? checkpoint.lastPushCursor,
            lastAckedChangeID: ackedChangeIDs.max() ?? checkpoint.lastAckedChangeID,
            lastFailedChangeID: checkpoint.lastFailedChangeID,
            lastSeenChangeID: (acceptedChangeIDs + ackedChangeIDs + [checkpoint.lastSeenChangeID].compactMap { $0 }).max(),
            lastSuccessfulSyncAt: finishedAt,
            lastSuccessfulPullAt: pulled.changes.isEmpty ? checkpoint.lastSuccessfulPullAt : finishedAt,
            lastSuccessfulPushAt: pushResponse.accepted.isEmpty ? checkpoint.lastSuccessfulPushAt : finishedAt,
            lastSuccessfulAckAt: ackItems.isEmpty ? checkpoint.lastSuccessfulAckAt : finishedAt,
            lastAppleScanStartedAt: startedAt,
            lastSyncStatus: "success",
            lastErrorCode: nil,
            lastErrorMessage: nil
        )
        try await dependencies.bridgeStore.saveCheckpoint(nextCheckpoint)

        let queuedRetryCount = try await queueRejectedMutations(pushResponse.rejectedReminderIDs, from: plan.remoteMutations)

        let report = SyncRunReport(
            startedAt: startedAt,
            finishedAt: finishedAt,
            pulledCount: pulled.changes.count,
            pushedCount: pushResponse.accepted.count,
            ackedCount: ackItems.count,
            conflictCount: plan.conflicts.count,
            queuedRetryCount: queuedRetryCount,
            consumedPendingCount: pendingResult.completedIDs.count
        )

        return SyncDebugSnapshot(
            checkpoint: checkpoint,
            pulledCount: pulled.changes.count,
            plannedPushMutationsCount: plan.remoteMutations.count,
            plannedPushMutationSummaries: plan.remoteMutations.map(Self.describe),
            pushRequestTasksCount: pushRequestTasks.count,
            pushRequestTaskSummaries: pushRequestTasks.map(Self.describe),
            pushResponseAcceptedCount: pushResponse.accepted.count,
            pushResponseAcceptedSummaries: pushResponse.accepted.map(Self.describe),
            pushResponseItemsCount: pushResponse.items.count,
            pushResponseItemSummaries: pushResponse.items.map(Self.describe),
            ackItemsCount: ackItems.count,
            ackItemSummaries: ackItems.map(Self.describe),
            report: report
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let operations = mutations.compactMap { mutation -> PendingOperation? in
            guard rejectedSet.contains(mutation.reminderID) else { return nil }
            let payload = try? encoder.encode(mutation)
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

    private func consumePendingOperations(_ operations: [PendingOperation], now: Date) async throws -> PendingExecutionResult {
        guard !operations.isEmpty else { return PendingExecutionResult() }
        let result = try await dependencies.pendingExecutor.execute(operations, now: now)
        if !result.completedIDs.isEmpty {
            try await dependencies.bridgeStore.removePendingOperations(ids: result.completedIDs)
        }
        let updated = result.updatedOperations.filter { !result.completedIDs.contains($0.id) }
        if !updated.isEmpty {
            try await dependencies.bridgeStore.updatePendingOperations(updated)
        }
        return result
    }

    private func buildPushTaskVersions(from mutations: [PushTaskMutation]) -> [PushTaskVersion] {
        mutations.compactMap { mutation in
            guard let taskID = mutation.taskID else { return nil }
            let version = mutation.backendVersionToken.flatMap(Self.extractVersionNumber) ?? 0
            return PushTaskVersion(taskID: taskID, version: version)
        }
    }

    private func buildAckItems(
        taskIDs: [String],
        acceptedPushes: [PushTaskResult],
        remoteItems: [RemoteTaskEnvelope],
        reminders: [ReminderRecord]
    ) -> [AckItem] {
        let reminderByTaskID = Dictionary(uniqueKeysWithValues: acceptedPushes.map { ($0.task.id, $0.reminderID) })
        let reminderByID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let remoteByTaskID = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.taskID, $0) })

        return taskIDs.compactMap { taskID in
            let remote = remoteByTaskID[taskID]
            let reminderID = reminderByTaskID[taskID]
            let reminder = reminderID.flatMap { reminderByID[$0] }
            let version = remote?.version ?? Self.extractVersionNumber(remote?.task.versionToken) ?? 0
            return AckItem(
                taskID: taskID,
                remoteID: reminder?.externalIdentifier,
                version: version,
                changeID: remote?.changeID ?? remote?.task.changeID,
                status: "success",
                appleModifiedAt: reminder?.lastModifiedAt,
                appleListID: reminder?.listIdentifier,
                appleCalendarID: reminder?.listIdentifier
            )
        }
    }

    private static func extractVersionNumber(_ versionToken: String?) -> Int? {
        guard let versionToken else { return nil }
        let digits = versionToken.filter(\.isNumber)
        return Int(digits)
    }

    private static func describe(_ mutation: PushTaskMutation) -> String {
        "reminderID=\(mutation.reminderID) taskID=\(mutation.taskID ?? "<new>") state=\(mutation.state.rawValue) title=\(mutation.title) versionToken=\(mutation.backendVersionToken ?? "<none>")"
    }

    private static func describe(_ task: PushTaskVersion) -> String {
        "taskID=\(task.taskID) version=\(task.version)"
    }

    private static func describe(_ result: PushTaskResult) -> String {
        "reminderID=\(result.reminderID) taskID=\(result.task.id) state=\(result.task.state.rawValue) versionToken=\(result.task.versionToken)"
    }

    private static func describe(_ item: RemoteTaskEnvelope) -> String {
        "taskID=\(item.taskID) changeID=\(item.changeID.map(String.init) ?? "<none>") version=\(item.version) operation=\(item.operation)"
    }

    private static func describe(_ ack: AckItem) -> String {
        "taskID=\(ack.taskID) changeID=\(ack.changeID.map(String.init) ?? "<none>") version=\(ack.version) status=\(ack.status)"
    }
}
