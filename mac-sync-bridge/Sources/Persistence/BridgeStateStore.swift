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

public struct SQLiteSchemaDefinition: Sendable {
    public let currentVersion: Int
    public let createStatements: [String]

    public init(currentVersion: Int = 1, createStatements: [String] = SQLiteSchemaDefinition.defaultStatements) {
        self.currentVersion = currentVersion
        self.createStatements = createStatements
    }

    public static let defaultStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS bridge_configuration (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            backend_base_url TEXT NOT NULL,
            api_token TEXT,
            sync_interval_seconds REAL NOT NULL,
            default_reminder_list_identifier TEXT,
            updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_checkpoint (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            backend_cursor TEXT,
            last_successful_sync_at TEXT,
            last_successful_pull_at TEXT,
            last_successful_push_at TEXT,
            last_successful_ack_at TEXT,
            last_apple_scan_started_at TEXT,
            last_sync_status TEXT,
            updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS reminder_task_mappings (
            reminder_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL UNIQUE,
            reminder_external_identifier TEXT,
            reminder_list_identifier TEXT,
            reminder_fingerprint TEXT NOT NULL,
            backend_version_token TEXT NOT NULL,
            sync_state TEXT NOT NULL,
            synced_at TEXT NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_mappings_task_id ON reminder_task_mappings(task_id);",
        "CREATE INDEX IF NOT EXISTS idx_mappings_sync_state ON reminder_task_mappings(sync_state);",
        """
        CREATE TABLE IF NOT EXISTS pending_operations (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            payload BLOB,
            status TEXT NOT NULL,
            last_error_message TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_pending_operations_retry ON pending_operations(status, next_retry_at);",
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        """
    ]
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
    func updatePendingOperations(_ operations: [PendingOperation]) async throws
    func removePendingOperations(ids: [UUID]) async throws
    func exportSQLiteSchema() -> SQLiteSchemaDefinition
}

public actor InMemoryBridgeStateStore: BridgeStateStore {
    private var configuration: BridgeConfiguration
    private var checkpoint: SyncCheckpoint
    private var mappingsByReminderID: [String: ReminderTaskMapping]
    private var pendingOperationsByID: [UUID: PendingOperation]
    private let schemaDefinition: SQLiteSchemaDefinition

    public init(
        configuration: BridgeConfiguration,
        checkpoint: SyncCheckpoint = .init(),
        mappings: [ReminderTaskMapping] = [],
        pendingOperations: [PendingOperation] = [],
        schemaDefinition: SQLiteSchemaDefinition = .init()
    ) {
        self.configuration = configuration
        self.checkpoint = checkpoint
        self.mappingsByReminderID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.reminderID, $0) })
        self.pendingOperationsByID = Dictionary(uniqueKeysWithValues: pendingOperations.map { ($0.id, $0) })
        self.schemaDefinition = schemaDefinition
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
        pendingOperationsByID.values.sorted {
            if $0.nextRetryAt == $1.nextRetryAt {
                return $0.createdAt < $1.createdAt
            }
            return ($0.nextRetryAt ?? .distantFuture) < ($1.nextRetryAt ?? .distantFuture)
        }
    }

    public func enqueuePendingOperations(_ operations: [PendingOperation]) async throws {
        for operation in operations {
            pendingOperationsByID[operation.id] = operation
        }
    }

    public func updatePendingOperations(_ operations: [PendingOperation]) async throws {
        for operation in operations {
            pendingOperationsByID[operation.id] = operation
        }
    }

    public func removePendingOperations(ids: [UUID]) async throws {
        for id in ids {
            pendingOperationsByID.removeValue(forKey: id)
        }
    }

    public func exportSQLiteSchema() -> SQLiteSchemaDefinition {
        schemaDefinition
    }
}
