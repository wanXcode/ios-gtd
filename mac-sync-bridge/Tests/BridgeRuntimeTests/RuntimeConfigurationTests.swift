import BridgeRuntime
import Foundation
import Testing

struct RuntimeConfigurationTests {
    @Test
    func environmentOverridesConfigFileDefaults() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let configURL = tempDirectory.appendingPathComponent("config.json")
        let fileConfig = BridgeRuntimeConfiguration(
            bridgeID: "file-bridge",
            backendBaseURL: URL(string: "https://file.example.com")!,
            apiToken: "file-token",
            sqlitePath: "/tmp/file.sqlite",
            syncIntervalSeconds: 120,
            defaultReminderListIdentifier: "file-list",
            syncedReminderListIdentifiers: ["file-a", "file-b"],
            includeCompletedReminders: false,
            backendTimeoutSeconds: 10
        )
        let encoder = JSONEncoder()
        try encoder.encode(fileConfig).write(to: configURL)

        let loader = BridgeRuntimeConfigurationLoader(
            environment: [
                "BRIDGE_BACKEND_BASE_URL": "https://env.example.com",
                "BRIDGE_API_TOKEN": "env-token",
                "BRIDGE_SQLITE_PATH": "/tmp/env.sqlite",
                "BRIDGE_ID": "env-bridge",
                "BRIDGE_SYNC_INTERVAL_SECONDS": "600",
                "BRIDGE_DEFAULT_LIST_ID": "env-list",
                "BRIDGE_SYNCED_LIST_IDS": "env-a,env-b",
                "BRIDGE_INCLUDE_COMPLETED": "true",
                "BRIDGE_BACKEND_TIMEOUT_SECONDS": "45"
            ]
        )

        let configuration = try loader.load(arguments: ["--config", configURL.path])

        #expect(configuration.bridgeID == "env-bridge")
        #expect(configuration.backendBaseURL.absoluteString == "https://env.example.com")
        #expect(configuration.apiToken == "env-token")
        #expect(configuration.sqlitePath == "/tmp/env.sqlite")
        #expect(configuration.syncIntervalSeconds == 600)
        #expect(configuration.defaultReminderListIdentifier == "env-list")
        #expect(configuration.syncedReminderListIdentifiers == ["env-a", "env-b"])
        #expect(configuration.includeCompletedReminders)
        #expect(configuration.backendTimeoutSeconds == 45)
    }

    @Test
    func commandLineOverridesEnvironment() throws {
        let loader = BridgeRuntimeConfigurationLoader(
            environment: [
                "BRIDGE_BACKEND_BASE_URL": "https://env.example.com",
                "BRIDGE_SQLITE_PATH": "/tmp/env.sqlite"
            ]
        )

        let configuration = try loader.load(arguments: [
            "--backend-base-url", "https://cli.example.com",
            "--sqlite-path", "/tmp/cli.sqlite",
            "--bridge-id=cli-bridge",
            "--synced-lists", "inbox,scheduled"
        ])

        #expect(configuration.backendBaseURL.absoluteString == "https://cli.example.com")
        #expect(configuration.sqlitePath == "/tmp/cli.sqlite")
        #expect(configuration.bridgeID == "cli-bridge")
        #expect(configuration.syncedReminderListIdentifiers == ["inbox", "scheduled"])
    }

    @Test
    func missingBackendBaseURLThrows() {
        let loader = BridgeRuntimeConfigurationLoader(environment: [:])
        #expect(throws: BridgeRuntimeConfigurationError.self) {
            try loader.load(arguments: [])
        }
    }

    @Test
    func invalidBooleanThrows() {
        let loader = BridgeRuntimeConfigurationLoader(
            environment: ["BRIDGE_BACKEND_BASE_URL": "https://env.example.com"]
        )

        #expect(throws: BridgeRuntimeConfigurationError.self) {
            try loader.load(arguments: ["--include-completed", "maybe"])
        }
    }
}
