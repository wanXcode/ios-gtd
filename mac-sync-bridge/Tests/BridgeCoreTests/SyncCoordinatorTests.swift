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
}
