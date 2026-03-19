import BridgeModels
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
            case "inspect-reminders":
                try await runInspectReminders(configuration: configuration)
            case "inspect-sync":
                try await runInspectSync(configuration: configuration)
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
        let defaultListIdentifier = persistedConfiguration.defaultReminderListIdentifier ?? "<none>"
        print("interval=\(Int(persistedConfiguration.syncIntervalSeconds))s")
        print("default_list=\(defaultListIdentifier)")
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

    private static func runInspectReminders(configuration: BridgeRuntimeConfiguration) async throws {
        let runtime = try await BridgeRuntimeConfigurationLoader().makeRuntime(configuration: configuration)
        let authorization = try await runtime.reminderStore.authorizationStatus()
        print("authorization=\(authorization.rawValue)")
        let reminders = try await runtime.reminderStore.fetchReminders()
        print("count=\(reminders.count)")
        for reminder in reminders.sorted(by: reminderSortKey) {
            print(format(reminder: reminder))
        }
    }

    private static func runInspectSync(configuration: BridgeRuntimeConfiguration) async throws {
        let runtime = try await BridgeRuntimeConfigurationLoader().makeRuntime(configuration: configuration)
        let authorization = try await runtime.reminderStore.authorizationStatus()
        let reminders = try await runtime.reminderStore.fetchReminders()
        let mappings = try await runtime.bridgeStore.loadMappings()
        let checkpoint = try await runtime.bridgeStore.loadCheckpoint()
        let plan = await runtime.coordinator.buildPlan(
            direction: .bidirectional,
            reminders: reminders,
            backendChanges: [],
            mappings: mappings
        )

        print("bridge_id=\(configuration.bridgeID)")
        print("authorization=\(authorization.rawValue)")
        print("backend=\(configuration.backendBaseURL.absoluteString)")
        print("sqlite=\(configuration.sqliteURL.path)")
        print("reminders_count=\(reminders.count)")
        print("mappings_count=\(mappings.count)")
        print("checkpoint=\(format(checkpoint: checkpoint))")
        print("push_mutations_count=\(plan.remoteMutations.count)")

        if !mappings.isEmpty {
            print("mappings:")
            for mapping in mappings.sorted(by: mappingSortKey) {
                print("  \(format(mapping: mapping))")
            }
        }

        if !plan.remoteMutations.isEmpty {
            print("push_mutations:")
            for mutation in plan.remoteMutations.sorted(by: mutationSortKey) {
                print("  \(format(mutation: mutation))")
            }
        }
    }

    private static func reminderSortKey(_ lhs: ReminderRecord, _ rhs: ReminderRecord) -> Bool {
        let lhsList = lhs.listIdentifier ?? ""
        let rhsList = rhs.listIdentifier ?? ""
        if lhsList != rhsList { return lhsList < rhsList }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func mappingSortKey(_ lhs: ReminderTaskMapping, _ rhs: ReminderTaskMapping) -> Bool {
        if lhs.reminderListIdentifier != rhs.reminderListIdentifier {
            return (lhs.reminderListIdentifier ?? "") < (rhs.reminderListIdentifier ?? "")
        }
        if lhs.taskID != rhs.taskID { return lhs.taskID < rhs.taskID }
        return lhs.reminderID < rhs.reminderID
    }

    private static func mutationSortKey(_ lhs: PushTaskMutation, _ rhs: PushTaskMutation) -> Bool {
        if (lhs.listIdentifier ?? "") != (rhs.listIdentifier ?? "") {
            return (lhs.listIdentifier ?? "") < (rhs.listIdentifier ?? "")
        }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        return lhs.reminderID < rhs.reminderID
    }

    private static func format(reminder: ReminderRecord) -> String {
        let listIdentifier = reminder.listIdentifier ?? "<none>"
        return [
            "id=\(shellEscaped(reminder.id))",
            "externalIdentifier=\(shellEscaped(reminder.externalIdentifier))",
            "title=\(shellEscaped(reminder.title))",
            "listIdentifier=\(shellEscaped(listIdentifier))",
            "isCompleted=\(reminder.isCompleted)",
            "isDeleted=\(reminder.isDeleted)",
            "lastModifiedAt=\(iso8601String(from: reminder.lastModifiedAt))"
        ].joined(separator: " ")
    }

    private static func format(mapping: ReminderTaskMapping) -> String {
        [
            "reminderID=\(shellEscaped(mapping.reminderID))",
            "taskID=\(shellEscaped(mapping.taskID))",
            "listIdentifier=\(shellEscaped(mapping.reminderListIdentifier ?? "<none>"))",
            "syncState=\(mapping.syncState.rawValue)",
            "backendVersionToken=\(shellEscaped(mapping.backendVersionToken))",
            "syncedAt=\(iso8601String(from: mapping.syncedAt))"
        ].joined(separator: " ")
    }

    private static func format(checkpoint: SyncCheckpoint) -> String {
        [
            "backendCursor=\(shellEscaped(checkpoint.backendCursor ?? "<none>"))",
            "lastPullCursor=\(shellEscaped(checkpoint.lastPullCursor ?? "<none>"))",
            "lastPushCursor=\(shellEscaped(checkpoint.lastPushCursor ?? "<none>"))",
            "lastAckedChangeID=\(checkpoint.lastAckedChangeID.map(String.init) ?? "<none>")",
            "lastFailedChangeID=\(checkpoint.lastFailedChangeID.map(String.init) ?? "<none>")",
            "lastSeenChangeID=\(checkpoint.lastSeenChangeID.map(String.init) ?? "<none>")",
            "lastSyncStatus=\(shellEscaped(checkpoint.lastSyncStatus ?? "<none>"))",
            "lastErrorCode=\(shellEscaped(checkpoint.lastErrorCode ?? "<none>"))",
            "lastErrorMessage=\(shellEscaped(checkpoint.lastErrorMessage ?? "<none>"))",
            "lastSuccessfulSyncAt=\(optionalDateString(checkpoint.lastSuccessfulSyncAt))",
            "lastSuccessfulPullAt=\(optionalDateString(checkpoint.lastSuccessfulPullAt))",
            "lastSuccessfulPushAt=\(optionalDateString(checkpoint.lastSuccessfulPushAt))",
            "lastSuccessfulAckAt=\(optionalDateString(checkpoint.lastSuccessfulAckAt))",
            "lastAppleScanStartedAt=\(optionalDateString(checkpoint.lastAppleScanStartedAt))"
        ].joined(separator: " ")
    }

    private static func format(mutation: PushTaskMutation) -> String {
        [
            "reminderID=\(shellEscaped(mutation.reminderID))",
            "taskID=\(shellEscaped(mutation.taskID ?? "<new>"))",
            "title=\(shellEscaped(mutation.title))",
            "listIdentifier=\(shellEscaped(mutation.listIdentifier ?? "<none>"))",
            "state=\(mutation.state.rawValue)",
            "backendVersionToken=\(shellEscaped(mutation.backendVersionToken ?? "<none>"))",
            "backendChangeID=\(mutation.backendChangeID.map(String.init) ?? "<none>")"
        ].joined(separator: " ")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func optionalDateString(_ date: Date?) -> String {
        guard let date else { return "<none>" }
        return iso8601String(from: date)
    }

    private static func shellEscaped(_ value: String) -> String {
        guard !value.isEmpty else { return "\"\"" }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func printConfig(configuration: BridgeRuntimeConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        print(String(decoding: data, as: UTF8.self))
    }
}
