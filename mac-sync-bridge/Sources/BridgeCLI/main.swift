import BridgeCore
import BridgeModels
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence

@main
struct BridgeCLIApp {
    static func main() async {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "doctor"
            switch command {
            case "doctor":
                try await runDoctor()
            case "sync-once", "run":
                try await runSyncOnce()
            case "print-config":
                try await printConfig()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                Foundation.exit(1)
            }
        } catch {
            fputs("bridge-cli failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func makeDependencies() -> SyncCoordinatorDependencies {
        let now = Date()
        let reminder = ReminderRecord(
            id: "local-reminder-1",
            externalIdentifier: "ek-local-reminder-1",
            title: "Sample reminder",
            notes: "Scaffold data",
            dueDate: nil,
            isCompleted: false,
            isDeleted: false,
            listIdentifier: "default",
            lastModifiedAt: now,
            fingerprint: ReminderFingerprint(value: "fp-local-1")
        )

        let reminderStore = InMemoryReminderStore(reminders: [reminder])
        let backendClient = InMemoryBackendSyncClient()
        let bridgeStore = InMemoryBridgeStateStore(
            configuration: BridgeConfiguration(
                backendBaseURL: URL(string: "http://127.0.0.1:8000")!,
                apiToken: nil,
                syncIntervalSeconds: 300,
                defaultReminderListIdentifier: "default"
            )
        )

        return SyncCoordinatorDependencies(
            reminderStore: reminderStore,
            backendClient: backendClient,
            bridgeStore: bridgeStore,
            conflictResolver: LastWriteWinsConflictResolver(),
            retryScheduler: ExponentialBackoffRetryScheduler()
        )
    }

    private static func runDoctor() async throws {
        let dependencies = makeDependencies()
        let authorization = try await dependencies.reminderStore.authorizationStatus()
        let configuration = try await dependencies.bridgeStore.loadConfiguration()
        print("authorization=\(authorization.rawValue)")
        print("backend=\(configuration.backendBaseURL.absoluteString)")
        print("interval=\(Int(configuration.syncIntervalSeconds))s")
    }

    private static func runSyncOnce() async throws {
        let coordinator = SyncCoordinator(dependencies: makeDependencies())
        let report = try await coordinator.runSync(direction: .bidirectional)
        print("sync finished pulled=\(report.pulledCount) pushed=\(report.pushedCount) acked=\(report.ackedCount) conflicts=\(report.conflictCount) retries=\(report.queuedRetryCount)")
    }

    private static func printConfig() async throws {
        let configuration = try await makeDependencies().bridgeStore.loadConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        print(String(decoding: data, as: UTF8.self))
    }
}
