import BridgeCore
import BridgeModels
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence
import Testing

struct SyncCoordinatorTests {
    @Test
    func unmappedReminderPushesAndPersistsMapping() async throws {
        let now = Date()
        let reminder = ReminderRecord(
            id: "r1",
            externalIdentifier: "ek-r1",
            title: "Buy milk",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            isDeleted: false,
            listIdentifier: "inbox",
            lastModifiedAt: now,
            fingerprint: ReminderFingerprint(value: "fp-r1-v1")
        )

        let reminderStore = InMemoryReminderStore(reminders: [reminder])
        let backendClient = InMemoryBackendSyncClient()
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!)
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler()
            )
        )

        let report = try await coordinator.runSync()
        let mappings = try await bridgeStore.loadMappings()

        #expect(report.pushedCount == 1)
        #expect(mappings.count == 1)
        #expect(mappings.first?.reminderID == "r1")
        #expect(mappings.first?.taskID.isEmpty == false)
    }

    @Test
    func backendChangePullsIntoLocalReminder() async throws {
        let now = Date()
        let remoteTask = BackendTaskRecord(
            id: "t1",
            title: "Remote change",
            notes: "from backend",
            dueDate: nil,
            state: .active,
            updatedAt: now,
            deletedAt: nil,
            versionToken: "v2"
        )
        let mapping = ReminderTaskMapping(
            reminderID: "r1",
            taskID: "t1",
            reminderFingerprint: ReminderFingerprint(value: "v1"),
            backendVersionToken: "v1",
            syncedAt: now.addingTimeInterval(-3600)
        )
        let localReminder = ReminderRecord(
            id: "r1",
            externalIdentifier: "ek-r1",
            title: "Old title",
            notes: nil,
            dueDate: nil,
            isCompleted: false,
            isDeleted: false,
            listIdentifier: "inbox",
            lastModifiedAt: now.addingTimeInterval(-7200),
            fingerprint: ReminderFingerprint(value: "v1")
        )

        let reminderStore = InMemoryReminderStore(reminders: [localReminder])
        let backendClient = InMemoryBackendSyncClient(tasks: [remoteTask])
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!),
            mappings: [mapping]
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler()
            )
        )

        let report = try await coordinator.runSync(direction: .pull)
        let reminders = try await reminderStore.fetchReminders()

        #expect(report.pulledCount == 1)
        #expect(reminders.first?.title == "Remote change")
        #expect(reminders.first?.notes == "from backend")
    }

    @Test
    func rejectedPushQueuesRetryOperation() async throws {
        let now = Date()
        let reminder = ReminderRecord(
            id: "r-retry",
            externalIdentifier: "ek-r-retry",
            title: "Retry me",
            notes: "backend rejected",
            dueDate: nil,
            isCompleted: false,
            isDeleted: false,
            listIdentifier: "inbox",
            lastModifiedAt: now,
            fingerprint: ReminderFingerprint(value: "fp-retry-1")
        )

        let reminderStore = InMemoryReminderStore(reminders: [reminder])
        let backendClient = RejectingBackendSyncClient(rejectedReminderIDs: ["r-retry"])
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!)
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(baseDelay: 10, maxDelay: 60)
            )
        )

        let report = try await coordinator.runSync(direction: .push)
        let pending = try await bridgeStore.loadPendingOperations()

        #expect(report.pushedCount == 0)
        #expect(report.queuedRetryCount == 1)
        #expect(pending.count == 1)
        #expect(pending.first?.entityID == "r-retry")
        #expect(pending.first?.status == .retrying)
        #expect(pending.first?.kind == .updateRemoteTask)
    }
}

private actor RejectingBackendSyncClient: BackendSyncClient {
    private let rejectedReminderIDs: [String]

    init(rejectedReminderIDs: [String]) {
        self.rejectedReminderIDs = rejectedReminderIDs
    }

    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        _ = request
        return PullChangesResponse(changes: [], nextCursor: "cursor-0", hasMore: false)
    }

    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        let rejected = Set(rejectedReminderIDs)
        let accepted = request.changes.compactMap { change -> PushTaskResult? in
            guard !rejected.contains(change.reminderID) else { return nil }
            return PushTaskResult(
                reminderID: change.reminderID,
                task: BackendTaskRecord(
                    id: change.taskID ?? "task-\(change.reminderID)",
                    title: change.title,
                    notes: change.notes,
                    dueDate: change.dueDate,
                    state: change.state,
                    updatedAt: change.lastModifiedAt,
                    versionToken: "v-accepted"
                )
            )
        }
        return PushChangesResponse(accepted: accepted, rejectedReminderIDs: rejectedReminderIDs)
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}
