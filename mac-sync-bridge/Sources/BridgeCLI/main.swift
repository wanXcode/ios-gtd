import BridgeRuntime
import Foundation

@main
struct BridgeCLIApp {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.first ?? "doctor"
            let runtimeArguments = Array(arguments.dropFirst())
            let loader = BridgeRuntimeConfigurationLoader()
            let configuration = try loader.load(arguments: runtimeArguments)

            switch command {
            case "doctor":
                try await runDoctor(configuration: configuration)
            case "list-lists":
                try await runListLists(configuration: configuration)
            case "sync-once", "run":
                try await runSyncOnce(configuration: configuration)
            case "print-config":
                try printConfig(configuration: configuration)
            default:
                fputs("Unknown command: \(command)\n", stderr)
                Foundation.exit(1)
            }
        } catch {
            fputs("bridge-cli failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func runDoctor(configuration: BridgeRuntimeConfiguration) async throws {
        let runtime = try await BridgeRuntimeConfigurationLoader().makeRuntime(configuration: configuration)
        let authorization = try await runtime.reminderStore.authorizationStatus()
        let persistedConfiguration = try await runtime.bridgeStore.loadConfiguration()
        let lists = try? await runtime.reminderStore.fetchReminderLists()

        print("bridge_id=\(configuration.bridgeID)")
        print("authorization=\(authorization.rawValue)")
        print("backend=\(persistedConfiguration.backendBaseURL.absoluteString)")
        print("sqlite=\(configuration.sqliteURL.path)")
        print("interval=\(Int(persistedConfiguration.syncIntervalSeconds))s")
        print("default_list=\(persistedConfiguration.defaultReminderListIdentifier ?? "<none>")")
        print("synced_lists=\(configuration.syncedReminderListIdentifiers.joined(separator: ","))")
        if let lists {
            print("discovered_lists=\(lists.count)")
            for list in lists {
                let sourceIdentifier = list.sourceIdentifier ?? "<unknown>"
                print("list.id=\(list.identifier) title=\(list.title) writable=\(list.allowsContentModifications) source=\(sourceIdentifier)")
            }
        }
    }

    private static func runListLists(configuration: BridgeRuntimeConfiguration) async throws {
        let runtime = try await BridgeRuntimeConfigurationLoader().makeRuntime(configuration: configuration)
        let authorization = try await runtime.reminderStore.authorizationStatus()
        print("authorization=\(authorization.rawValue)")
        let lists = try await runtime.reminderStore.fetchReminderLists()
        for list in lists {
            let sourceIdentifier = list.sourceIdentifier ?? "<unknown>"
            print("\(list.identifier)\t\(list.title)\twritable=\(list.allowsContentModifications)\tsource=\(sourceIdentifier)")
        }
    }

    private static func runSyncOnce(configuration: BridgeRuntimeConfiguration) async throws {
        let runtime = try await BridgeRuntimeConfigurationLoader().makeRuntime(configuration: configuration)
        let report = try await runtime.coordinator.runSync(direction: .bidirectional)
        print("sync finished bridge_id=\(configuration.bridgeID) pulled=\(report.pulledCount) pushed=\(report.pushedCount) acked=\(report.ackedCount) conflicts=\(report.conflictCount) retries=\(report.queuedRetryCount) pending_consumed=\(report.consumedPendingCount)")
    }

    private static func printConfig(configuration: BridgeRuntimeConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        print(String(decoding: data, as: UTF8.self))
    }
}
