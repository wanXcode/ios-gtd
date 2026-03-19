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

        let nextCheckpoint = SyncCheckpoint(
            backendCursor: pulled.nextCursor ?? checkpoint.backendCursor,
            lastSuccessfulSyncAt: dependencies.dateProvider.now()
        )
        try await dependencies.bridgeStore.saveCheckpoint(nextCheckpoint)

        let queuedRetryCount = try await queueRejectedMutations(pushResponse.rejectedReminderIDs, from: plan.remoteMutations)
        let finishedAt = dependencies.dateProvider.now()

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

        var localUpserts: [ReminderRecord] = []
        var localDeletes: [ReminderRecord] = []
        var remoteMutations: [PushTaskMutation] = []
        var ackTaskIDs: [String] = []
        var conflicts: [SyncConflict] = []

        if direction != .push {
            for task in backendChanges {
                if let mapping = mappingByTaskID[task.id], let reminder = reminderByID[mapping.reminderID] {
                    let reminderChanged = reminder.fingerprint != mapping.reminderFingerprint
                    let backendChanged = task.versionToken != mapping.backendVersionToken

                    if reminderChanged && backendChanged {
                        let resolution = dependencies.conflictResolver.resolve(reminder: reminder, backendTask: task)
                        conflicts.append(SyncConflict(reminder: reminder, backendTask: task, resolution: resolution))
                        switch resolution {
                        case .backendWins, .lastWriteWins:
                            if let resolved = reminderRecord(from: task, existingReminderID: reminder.id, externalIdentifier: reminder.externalIdentifier) {
                                if task.state == .deleted {
                                    localDeletes.append(resolved)
                                } else {
                                    localUpserts.append(resolved)
                                }
                            }
                            ackTaskIDs.append(task.id)
                        case .reminderWins:
                            remoteMutations.append(pushMutation(from: reminder, mappedTaskID: task.id))
                        case .manualReview:
                            break
                        }
                    } else if backendChanged {
                        if let resolved = reminderRecord(from: task, existingReminderID: reminder.id, externalIdentifier: reminder.externalIdentifier) {
                            if task.state == .deleted {
                                localDeletes.append(resolved)
                            } else {
                                localUpserts.append(resolved)
                            }
                        }
                        ackTaskIDs.append(task.id)
                    }
                } else if let newReminder = reminderRecord(from: task, existingReminderID: UUID().uuidString, externalIdentifier: UUID().uuidString) {
                    if task.state == .deleted {
                        continue
                    }
                    localUpserts.append(newReminder)
                    ackTaskIDs.append(task.id)
                }
            }
        }

        if direction != .pull {
            for reminder in reminders {
                if let mapping = mappingByReminderID[reminder.id] {
                    let fingerprintChanged = reminder.fingerprint != mapping.reminderFingerprint
                    if fingerprintChanged {
                        remoteMutations.append(pushMutation(from: reminder, mappedTaskID: mapping.taskID))
                    }
                } else if !reminder.isDeleted {
                    remoteMutations.append(pushMutation(from: reminder, mappedTaskID: nil))
                }
            }
        }

        return SyncPlan(
            localUpserts: localUpserts,
            localDeletes: localDeletes,
            remoteMutations: remoteMutations,
            ackTaskIDs: ackTaskIDs,
            conflicts: conflicts
        )
    }

    private func reminderRecord(from task: BackendTaskRecord, existingReminderID: String, externalIdentifier: String) -> ReminderRecord? {
        ReminderRecord(
            id: existingReminderID,
            externalIdentifier: externalIdentifier,
            title: task.title,
            notes: task.notes,
            dueDate: task.dueDate,
            isCompleted: task.state == .completed,
            isDeleted: task.state == .deleted,
            listIdentifier: nil,
            lastModifiedAt: task.updatedAt,
            fingerprint: ReminderFingerprint(value: task.versionToken)
        )
    }

    private func pushMutation(from reminder: ReminderRecord, mappedTaskID: String?) -> PushTaskMutation {
        PushTaskMutation(
            taskID: mappedTaskID,
            reminderID: reminder.id,
            title: reminder.title,
            notes: reminder.notes,
            dueDate: reminder.dueDate,
            state: reminder.isDeleted ? .deleted : (reminder.isCompleted ? .completed : .active),
            fingerprint: reminder.fingerprint,
            lastModifiedAt: reminder.lastModifiedAt
        )
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
                reminderFingerprint: reminder.fingerprint,
                backendVersionToken: result.task.versionToken,
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
