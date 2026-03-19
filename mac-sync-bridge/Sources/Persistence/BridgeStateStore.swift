import BridgeModels
import Foundation

public struct BridgeConfiguration: Codable, Hashable, Sendable {
    public var backendBaseURL: URL
    public var apiToken: String?
    public var syncIntervalSeconds: TimeInterval
    public var defaultReminderListIdentifier: String?

    public init(
        backendBaseURL: URL,
        apiToken: String? = nil,
        syncIntervalSeconds: TimeInterval = 300,
        defaultReminderListIdentifier: String? = nil
    ) {
        self.backendBaseURL = backendBaseURL
        self.apiToken = apiToken
        self.syncIntervalSeconds = syncIntervalSeconds
        self.defaultReminderListIdentifier = defaultReminderListIdentifier
    }
}

public protocol BridgeStateStore: Sendable {
    func loadConfiguration() async throws -> BridgeConfiguration
    func saveConfiguration(_ configuration: BridgeConfiguration) async throws
    func loadCheckpoint() async throws -> SyncCheckpoint
    func saveCheckpoint(_ checkpoint: SyncCheckpoint) async throws
    func loadMappings() async throws -> [ReminderTaskMapping]
    func saveMappings(_ mappings: [ReminderTaskMapping]) async throws
    func loadPendingOperations() async throws -> [PendingOperation]
    func enqueuePendingOperations(_ operations: [PendingOperation]) async throws
}

public actor InMemoryBridgeStateStore: BridgeStateStore {
    private var configuration: BridgeConfiguration
    private var checkpoint: SyncCheckpoint
    private var mappingsByReminderID: [String: ReminderTaskMapping]
    private var pendingOperations: [PendingOperation]

    public init(
        configuration: BridgeConfiguration,
        checkpoint: SyncCheckpoint = .init(),
        mappings: [ReminderTaskMapping] = [],
        pendingOperations: [PendingOperation] = []
    ) {
        self.configuration = configuration
        self.checkpoint = checkpoint
        self.mappingsByReminderID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.reminderID, $0) })
        self.pendingOperations = pendingOperations
    }

    public func loadConfiguration() async throws -> BridgeConfiguration {
        configuration
    }

    public func saveConfiguration(_ configuration: BridgeConfiguration) async throws {
        self.configuration = configuration
    }

    public func loadCheckpoint() async throws -> SyncCheckpoint {
        checkpoint
    }

    public func saveCheckpoint(_ checkpoint: SyncCheckpoint) async throws {
        self.checkpoint = checkpoint
    }

    public func loadMappings() async throws -> [ReminderTaskMapping] {
        mappingsByReminderID.values.sorted { $0.reminderID < $1.reminderID }
    }

    public func saveMappings(_ mappings: [ReminderTaskMapping]) async throws {
        for mapping in mappings {
            mappingsByReminderID[mapping.reminderID] = mapping
        }
    }

    public func loadPendingOperations() async throws -> [PendingOperation] {
        pendingOperations.sorted { $0.createdAt < $1.createdAt }
    }

    public func enqueuePendingOperations(_ operations: [PendingOperation]) async throws {
        pendingOperations.append(contentsOf: operations)
    }
}
