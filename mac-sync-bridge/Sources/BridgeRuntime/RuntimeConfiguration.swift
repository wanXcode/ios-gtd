import BridgeCore
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence

public struct BridgeRuntimeConfiguration: Codable, Hashable, Sendable {
    public var bridgeID: String
    public var backendBaseURL: URL
    public var apiToken: String?
    public var sqlitePath: String
    public var syncIntervalSeconds: TimeInterval
    public var defaultReminderListIdentifier: String?
    public var syncedReminderListIdentifiers: [String]
    public var includeCompletedReminders: Bool
    public var backendTimeoutSeconds: TimeInterval

    public init(
        bridgeID: String = ProcessInfo.processInfo.hostName,
        backendBaseURL: URL,
        apiToken: String? = nil,
        sqlitePath: String = BridgeRuntimeConfiguration.defaultSQLitePath,
        syncIntervalSeconds: TimeInterval = 300,
        defaultReminderListIdentifier: String? = nil,
        syncedReminderListIdentifiers: [String] = [],
        includeCompletedReminders: Bool = true,
        backendTimeoutSeconds: TimeInterval = 30
    ) {
        self.bridgeID = bridgeID
        self.backendBaseURL = backendBaseURL
        self.apiToken = apiToken
        self.sqlitePath = sqlitePath
        self.syncIntervalSeconds = syncIntervalSeconds
        self.defaultReminderListIdentifier = defaultReminderListIdentifier
        self.syncedReminderListIdentifiers = syncedReminderListIdentifiers
        self.includeCompletedReminders = includeCompletedReminders
        self.backendTimeoutSeconds = backendTimeoutSeconds
    }

    public var sqliteURL: URL {
        URL(fileURLWithPath: NSString(string: sqlitePath).expandingTildeInPath)
    }

    public var persistenceConfiguration: BridgeConfiguration {
        BridgeConfiguration(
            backendBaseURL: backendBaseURL,
            apiToken: apiToken,
            syncIntervalSeconds: syncIntervalSeconds,
            defaultReminderListIdentifier: defaultReminderListIdentifier
        )
    }

    public var reminderStoreConfiguration: EventKitReminderStoreConfiguration {
        EventKitReminderStoreConfiguration(
            syncedListIdentifiers: Set(syncedReminderListIdentifiers),
            defaultListIdentifier: defaultReminderListIdentifier,
            includeCompleted: includeCompletedReminders
        )
    }

    public var backendClientConfiguration: BackendClientConfiguration {
        BackendClientConfiguration(
            baseURL: backendBaseURL,
            apiToken: apiToken,
            timeout: backendTimeoutSeconds
        )
    }

    public static let defaultSQLitePath = "~/Library/Application Support/GTD/mac-sync-bridge/bridge-state.sqlite"
    public static let defaultConfigPath = "~/Library/Application Support/GTD/mac-sync-bridge/config.json"
}

public enum BridgeRuntimeConfigurationError: Error, Sendable, LocalizedError {
    case missingBackendBaseURL
    case invalidBackendBaseURL(String)
    case invalidNumber(name: String, value: String)
    case invalidBoolean(name: String, value: String)
    case unreadableConfigFile(String)
    case invalidConfigFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingBackendBaseURL:
            return "Missing backend base URL. Set BRIDGE_BACKEND_BASE_URL or provide a config file."
        case let .invalidBackendBaseURL(value):
            return "Invalid backend base URL: \(value)"
        case let .invalidNumber(name, value):
            return "Invalid numeric value for \(name): \(value)"
        case let .invalidBoolean(name, value):
            return "Invalid boolean value for \(name): \(value)"
        case let .unreadableConfigFile(path):
            return "Unable to read config file at \(path)"
        case let .invalidConfigFile(message):
            return "Invalid config file: \(message)"
        }
    }
}

public struct BridgeRuntimeConfigurationLoader: Sendable {
    public var environment: [String: String]
    public var fileManager: FileManager
    public var processInfoProvider: @Sendable () -> ProcessInfo

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        processInfoProvider: @escaping @Sendable () -> ProcessInfo = { ProcessInfo.processInfo }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.processInfoProvider = processInfoProvider
    }

    public func load(arguments: [String]) throws -> BridgeRuntimeConfiguration {
        let options = try parse(arguments: arguments)
        let explicitConfigPath = options["config"] ?? environment["BRIDGE_CONFIG_PATH"]
        let configPath = explicitConfigPath ?? BridgeRuntimeConfiguration.defaultConfigPath

        var fileConfiguration: BridgeRuntimeConfiguration?
        if let explicitConfigPath || fileManager.fileExists(atPath: expandedPath(configPath)) {
            fileConfiguration = try loadConfigurationFile(at: explicitConfigPath ?? configPath)
        }

        let merged = try merge(fileConfiguration: fileConfiguration, options: options)
        return merged
    }

    public func makeRuntime(configuration: BridgeRuntimeConfiguration) async throws -> BridgeRuntime {
        let bridgeStore = try await SQLiteBridgeStateStore(
            databaseURL: configuration.sqliteURL,
            defaultConfiguration: configuration.persistenceConfiguration
        )
        try await bridgeStore.saveConfiguration(configuration.persistenceConfiguration)

        let reminderStore = EventKitReminderStore(configuration: configuration.reminderStoreConfiguration)
        let backendClient = URLSessionBackendSyncClient(configuration: configuration.backendClientConfiguration)
        let retryScheduler = ExponentialBackoffRetryScheduler()
        let dependencies = SyncCoordinatorDependencies(
            reminderStore: reminderStore,
            backendClient: backendClient,
            bridgeStore: bridgeStore,
            conflictResolver: LastWriteWinsConflictResolver(),
            retryScheduler: retryScheduler,
            bridgeID: configuration.bridgeID
        )
        return BridgeRuntime(configuration: configuration, coordinator: SyncCoordinator(dependencies: dependencies), bridgeStore: bridgeStore, reminderStore: reminderStore)
    }

    private func merge(
        fileConfiguration: BridgeRuntimeConfiguration?,
        options: [String: String]
    ) throws -> BridgeRuntimeConfiguration {
        let bridgeID = options["bridge-id"]
            ?? environment["BRIDGE_ID"]
            ?? fileConfiguration?.bridgeID
            ?? processInfoProvider().hostName

        let backendBaseURLString = options["backend-base-url"]
            ?? environment["BRIDGE_BACKEND_BASE_URL"]
            ?? fileConfiguration?.backendBaseURL.absoluteString
        guard let backendBaseURLString else {
            throw BridgeRuntimeConfigurationError.missingBackendBaseURL
        }
        guard let backendBaseURL = URL(string: backendBaseURLString) else {
            throw BridgeRuntimeConfigurationError.invalidBackendBaseURL(backendBaseURLString)
        }

        let apiToken = options["api-token"]
            ?? environment["BRIDGE_API_TOKEN"]
            ?? fileConfiguration?.apiToken

        let sqlitePath = options["sqlite-path"]
            ?? environment["BRIDGE_SQLITE_PATH"]
            ?? fileConfiguration?.sqlitePath
            ?? BridgeRuntimeConfiguration.defaultSQLitePath

        let syncIntervalSeconds = try resolveDouble(
            optionValue: options["sync-interval"],
            envValue: environment["BRIDGE_SYNC_INTERVAL_SECONDS"],
            fallback: fileConfiguration?.syncIntervalSeconds ?? 300,
            name: "sync-interval"
        )

        let backendTimeoutSeconds = try resolveDouble(
            optionValue: options["backend-timeout"],
            envValue: environment["BRIDGE_BACKEND_TIMEOUT_SECONDS"],
            fallback: fileConfiguration?.backendTimeoutSeconds ?? 30,
            name: "backend-timeout"
        )

        let defaultReminderListIdentifier = options["default-list"]
            ?? environment["BRIDGE_DEFAULT_LIST_ID"]
            ?? fileConfiguration?.defaultReminderListIdentifier

        let syncedReminderListIdentifiers = resolveStringList(
            optionValue: options["synced-lists"],
            envValue: environment["BRIDGE_SYNCED_LIST_IDS"],
            fallback: fileConfiguration?.syncedReminderListIdentifiers ?? []
        )

        let includeCompletedReminders = try resolveBool(
            optionValue: options["include-completed"],
            envValue: environment["BRIDGE_INCLUDE_COMPLETED"],
            fallback: fileConfiguration?.includeCompletedReminders ?? true,
            name: "include-completed"
        )

        return BridgeRuntimeConfiguration(
            bridgeID: bridgeID,
            backendBaseURL: backendBaseURL,
            apiToken: apiToken,
            sqlitePath: sqlitePath,
            syncIntervalSeconds: syncIntervalSeconds,
            defaultReminderListIdentifier: defaultReminderListIdentifier,
            syncedReminderListIdentifiers: syncedReminderListIdentifiers,
            includeCompletedReminders: includeCompletedReminders,
            backendTimeoutSeconds: backendTimeoutSeconds
        )
    }

    private func parse(arguments: [String]) throws -> [String: String] {
        var parsed: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }

            let trimmed = String(argument.dropFirst(2))
            if let separatorIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<separatorIndex])
                let value = String(trimmed[trimmed.index(after: separatorIndex)...])
                parsed[key] = value
                index += 1
                continue
            }

            let key = trimmed
            let nextIndex = index + 1
            if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                parsed[key] = arguments[nextIndex]
                index += 2
            } else {
                parsed[key] = "true"
                index += 1
            }
        }

        return parsed
    }

    private func loadConfigurationFile(at path: String) throws -> BridgeRuntimeConfiguration {
        let expanded = expandedPath(path)
        guard fileManager.fileExists(atPath: expanded) else {
            throw BridgeRuntimeConfigurationError.unreadableConfigFile(expanded)
        }
        guard let data = fileManager.contents(atPath: expanded) else {
            throw BridgeRuntimeConfigurationError.unreadableConfigFile(expanded)
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(BridgeRuntimeConfiguration.self, from: data)
        } catch {
            throw BridgeRuntimeConfigurationError.invalidConfigFile(String(describing: error))
        }
    }

    private func resolveDouble(optionValue: String?, envValue: String?, fallback: Double, name: String) throws -> Double {
        if let optionValue {
            guard let parsed = Double(optionValue) else {
                throw BridgeRuntimeConfigurationError.invalidNumber(name: name, value: optionValue)
            }
            return parsed
        }
        if let envValue {
            guard let parsed = Double(envValue) else {
                throw BridgeRuntimeConfigurationError.invalidNumber(name: name, value: envValue)
            }
            return parsed
        }
        return fallback
    }

    private func resolveBool(optionValue: String?, envValue: String?, fallback: Bool, name: String) throws -> Bool {
        if let optionValue {
            guard let parsed = Self.parseBool(optionValue) else {
                throw BridgeRuntimeConfigurationError.invalidBoolean(name: name, value: optionValue)
            }
            return parsed
        }
        if let envValue {
            guard let parsed = Self.parseBool(envValue) else {
                throw BridgeRuntimeConfigurationError.invalidBoolean(name: name, value: envValue)
            }
            return parsed
        }
        return fallback
    }

    private func resolveStringList(optionValue: String?, envValue: String?, fallback: [String]) -> [String] {
        let source = optionValue ?? envValue
        guard let source else { return fallback }
        return source
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }
}

public struct BridgeRuntime: Sendable {
    public let configuration: BridgeRuntimeConfiguration
    public let coordinator: SyncCoordinator
    public let bridgeStore: any BridgeStateStore
    public let reminderStore: any ReminderStore

    public init(
        configuration: BridgeRuntimeConfiguration,
        coordinator: SyncCoordinator,
        bridgeStore: any BridgeStateStore,
        reminderStore: any ReminderStore
    ) {
        self.configuration = configuration
        self.coordinator = coordinator
        self.bridgeStore = bridgeStore
        self.reminderStore = reminderStore
    }
}
