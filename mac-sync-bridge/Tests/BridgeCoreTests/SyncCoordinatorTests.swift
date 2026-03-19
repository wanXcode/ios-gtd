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
        let remoteTask = BackendTaskRecord(
            id: "t-generated",
            title: "Buy milk",
            notes: nil,
            dueDate: nil,
            state: .active,
            updatedAt: now,
            versionToken: "v1",
            sourceRecordID: "r1"
        )
        let backendClient = StaticPushBackendSyncClient(items: [
            RemoteTaskEnvelope(taskID: "t-generated", version: 1, changeID: 1, operation: "upsert", task: remoteTask)
        ])
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!)
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(),
                bridgeID: "test-bridge"
            )
        )

        let report = try await coordinator.runSync(direction: .push)
        let mappings = try await bridgeStore.loadMappings()

        #expect(report.pushedCount == 1)
        #expect(mappings.count == 1)
        #expect(mappings.first?.reminderID == "r1")
        #expect(mappings.first?.taskID == "t-generated")
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
            versionToken: "v2",
            sourceRecordID: "ek-r1",
            sourceListID: "inbox"
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
                retryScheduler: ExponentialBackoffRetryScheduler(),
                bridgeID: "test-bridge"
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
                retryScheduler: ExponentialBackoffRetryScheduler(baseDelay: 10, maxDelay: 60),
                bridgeID: "test-bridge"
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

    @Test
    func debugSnapshotKeepsCreateMutationInPushRequestAssembly() async throws {
        let now = Date()
        let reminder = ReminderRecord(
            id: "r-new",
            externalIdentifier: "ek-r-new",
            title: "New local reminder",
            notes: "not mapped yet",
            dueDate: nil,
            isCompleted: false,
            isDeleted: false,
            listIdentifier: "inbox",
            lastModifiedAt: now,
            fingerprint: ReminderFingerprint(value: "fp-r-new-v1")
        )

        let reminderStore = InMemoryReminderStore(reminders: [reminder])
        let backendClient = RecordingBackendSyncClient()
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!)
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(),
                bridgeID: "test-bridge"
            )
        )

        let snapshot = try await coordinator.runSyncWithDebug(direction: .push)
        let pushedRequests = await backendClient.pushedRequests

        #expect(snapshot.plannedPushMutationsCount == 1)
        #expect(snapshot.pushRequestTasksCount == 1)
        #expect(snapshot.report.pushedCount == 1)
        #expect(pushedRequests.count == 1)
        #expect(pushedRequests.first?.tasks.count == 1)
        #expect(pushedRequests.first?.tasks.first?.taskID == nil)
        #expect(pushedRequests.first?.tasks.first?.reminderID == "r-new")
    }

    @Test
    func pendingOperationsAreConsumedBeforeMainSync() async throws {
        let now = Date()
        let mutation = PushTaskMutation(
            taskID: "t-pending",
            reminderID: "r-pending",
            title: "Pending",
            state: .active,
            fingerprint: ReminderFingerprint(value: "fp-pending"),
            lastModifiedAt: now,
            backendVersionToken: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let pending = PendingOperation(
            kind: .updateRemoteTask,
            entityID: "r-pending",
            payload: try encoder.encode(mutation),
            status: .retrying,
            attemptCount: 1,
            nextRetryAt: now.addingTimeInterval(-5),
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60)
        )

        let reminderStore = InMemoryReminderStore(reminders: [])
        let backendClient = AcceptingPendingBackendSyncClient()
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(backendBaseURL: URL(string: "http://127.0.0.1:8000")!),
            pendingOperations: [pending]
        )
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: reminderStore,
                backendClient: backendClient,
                bridgeStore: bridgeStore,
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(),
                bridgeID: "test-bridge"
            )
        )

        let report = try await coordinator.runSync(direction: .pull)
        let remaining = try await bridgeStore.loadPendingOperations()

        #expect(report.consumedPendingCount == 1)
        #expect(remaining.isEmpty)
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
        _ = request
        return PushChangesResponse(accepted: [], rejectedReminderIDs: rejectedReminderIDs)
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}

private actor StaticPushBackendSyncClient: BackendSyncClient {
    private let items: [RemoteTaskEnvelope]

    init(items: [RemoteTaskEnvelope]) {
        self.items = items
    }

    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        _ = request
        return PullChangesResponse(changes: [], nextCursor: nil, hasMore: false)
    }

    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        _ = request
        let accepted = items.map { PushTaskResult(reminderID: $0.task.sourceRecordID ?? $0.taskID, task: $0.task) }
        return PushChangesResponse(accepted: accepted, items: items, nextCursor: items.last?.changeID.map(String.init), hasMore: false)
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}

private actor AcceptingPendingBackendSyncClient: BackendSyncClient {
    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        _ = request
        return PullChangesResponse(changes: [], nextCursor: nil, hasMore: false)
    }

    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        let accepted = request.tasks.map {
            PushTaskResult(
                reminderID: "r-pending",
                task: BackendTaskRecord(
                    id: $0.taskID,
                    title: "Pending",
                    state: .active,
                    updatedAt: Date(),
                    versionToken: "v\($0.version)"
                )
            )
        }
        return PushChangesResponse(accepted: accepted)
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}

private actor RecordingBackendSyncClient: BackendSyncClient {
    private(set) var pushedRequests: [PushChangesRequest] = []

    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        _ = request
        return PullChangesResponse(changes: [], nextCursor: nil, hasMore: false)
    }

    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        pushedRequests.append(request)
        let accepted = request.tasks.map { mutation in
            PushTaskResult(
                reminderID: mutation.reminderID,
                task: BackendTaskRecord(
                    id: mutation.taskID ?? "generated-\(mutation.reminderID)",
                    title: mutation.title,
                    notes: mutation.notes,
                    dueDate: mutation.dueDate,
                    remindAt: mutation.remindAt,
                    isAllDayDue: mutation.isAllDayDue,
                    priority: mutation.priority,
                    listName: mutation.listName,
                    state: mutation.state,
                    updatedAt: mutation.lastModifiedAt,
                    versionToken: mutation.backendVersionToken ?? "v1",
                    sourceRecordID: mutation.reminderID,
                    sourceListID: mutation.listIdentifier,
                    sourceCalendarID: mutation.listIdentifier
                )
            )
        }
        return PushChangesResponse(accepted: accepted, items: [])
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}
