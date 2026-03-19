import BridgeModels
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

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
            last_pull_cursor TEXT,
            last_push_cursor TEXT,
            last_acked_change_id INTEGER,
            last_failed_change_id INTEGER,
            last_seen_change_id INTEGER,
            last_successful_sync_at TEXT,
            last_successful_pull_at TEXT,
            last_successful_push_at TEXT,
            last_successful_ack_at TEXT,
            last_apple_scan_started_at TEXT,
            last_sync_status TEXT,
            last_error_code TEXT,
            last_error_message TEXT,
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

public enum SQLiteBridgeStateStoreError: Error, Sendable, LocalizedError {
    case sqliteUnavailable
    case openDatabaseFailed(path: String, code: Int32, message: String)
    case executeFailed(sql: String, code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case stepFailed(sql: String, code: Int32, message: String)
    case invalidConfiguration(String)
    case invalidCheckpoint(String)
    case invalidMapping(String)
    case invalidPendingOperation(String)

    public var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return "SQLite3 is unavailable in this build environment"
        case let .openDatabaseFailed(path, code, message):
            return "Failed to open SQLite database at \(path) (code=\(code)): \(message)"
        case let .executeFailed(sql, code, message):
            return "Failed to execute SQL [\(sql)] (code=\(code)): \(message)"
        case let .prepareFailed(sql, code, message):
            return "Failed to prepare SQL [\(sql)] (code=\(code)): \(message)"
        case let .stepFailed(sql, code, message):
            return "Failed to step SQL [\(sql)] (code=\(code)): \(message)"
        case let .invalidConfiguration(message):
            return "Invalid bridge configuration row: \(message)"
        case let .invalidCheckpoint(message):
            return "Invalid checkpoint row: \(message)"
        case let .invalidMapping(message):
            return "Invalid mapping row: \(message)"
        case let .invalidPendingOperation(message):
            return "Invalid pending operation row: \(message)"
        }
    }
}

public actor SQLiteBridgeStateStore: @preconcurrency BridgeStateStore {
    private let databaseURL: URL
    private let schemaDefinition: SQLiteSchemaDefinition
    private let defaultConfiguration: BridgeConfiguration
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(
        databaseURL: URL,
        defaultConfiguration: BridgeConfiguration,
        schemaDefinition: SQLiteSchemaDefinition = .init(),
        jsonEncoder: JSONEncoder = SQLiteBridgeStateStore.defaultJSONEncoder(),
        jsonDecoder: JSONDecoder = SQLiteBridgeStateStore.defaultJSONDecoder()
    ) async throws {
        self.databaseURL = databaseURL
        self.schemaDefinition = schemaDefinition
        self.defaultConfiguration = defaultConfiguration
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await migrateIfNeeded()
        try await seedDefaultsIfNeeded()
    }

    public func loadConfiguration() async throws -> BridgeConfiguration {
        try withDatabase { database in
            let sql = "SELECT backend_base_url, api_token, sync_interval_seconds, default_reminder_list_identifier FROM bridge_configuration WHERE id = 1 LIMIT 1;"
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            guard statement.step() == .row else {
                return defaultConfiguration
            }

            let urlString = statement.text(at: 0) ?? ""
            guard let url = URL(string: urlString) else {
                throw SQLiteBridgeStateStoreError.invalidConfiguration("backend_base_url is missing or malformed")
            }

            return BridgeConfiguration(
                backendBaseURL: url,
                apiToken: statement.optionalText(at: 1),
                syncIntervalSeconds: statement.double(at: 2),
                defaultReminderListIdentifier: statement.optionalText(at: 3)
            )
        }
    }

    public func saveConfiguration(_ configuration: BridgeConfiguration) async throws {
        try withDatabase { database in
            let now = Self.iso8601String(from: Date()) ?? ""
            let sql = """
            INSERT INTO bridge_configuration (
                id,
                backend_base_url,
                api_token,
                sync_interval_seconds,
                default_reminder_list_identifier,
                updated_at
            ) VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                backend_base_url = excluded.backend_base_url,
                api_token = excluded.api_token,
                sync_interval_seconds = excluded.sync_interval_seconds,
                default_reminder_list_identifier = excluded.default_reminder_list_identifier,
                updated_at = excluded.updated_at;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }
            statement.bind(text: configuration.backendBaseURL.absoluteString, at: 1)
            statement.bind(optionalText: configuration.apiToken, at: 2)
            statement.bind(double: configuration.syncIntervalSeconds, at: 3)
            statement.bind(optionalText: configuration.defaultReminderListIdentifier, at: 4)
            statement.bind(text: now, at: 5)
            try statement.runToCompletion()
        }
    }

    public func loadCheckpoint() async throws -> SyncCheckpoint {
        try withDatabase { database in
            let sql = """
            SELECT backend_cursor,
                   last_pull_cursor,
                   last_push_cursor,
                   last_acked_change_id,
                   last_failed_change_id,
                   last_seen_change_id,
                   last_successful_sync_at,
                   last_successful_pull_at,
                   last_successful_push_at,
                   last_successful_ack_at,
                   last_apple_scan_started_at,
                   last_sync_status,
                   last_error_code,
                   last_error_message
            FROM sync_checkpoint
            WHERE id = 1
            LIMIT 1;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            guard statement.step() == .row else {
                return SyncCheckpoint()
            }

            return SyncCheckpoint(
                backendCursor: statement.optionalText(at: 0),
                lastPullCursor: statement.optionalText(at: 1),
                lastPushCursor: statement.optionalText(at: 2),
                lastAckedChangeID: statement.optionalInt(at: 3),
                lastFailedChangeID: statement.optionalInt(at: 4),
                lastSeenChangeID: statement.optionalInt(at: 5),
                lastSuccessfulSyncAt: try Self.date(fromSQLiteText: statement.optionalText(at: 6), field: "last_successful_sync_at"),
                lastSuccessfulPullAt: try Self.date(fromSQLiteText: statement.optionalText(at: 7), field: "last_successful_pull_at"),
                lastSuccessfulPushAt: try Self.date(fromSQLiteText: statement.optionalText(at: 8), field: "last_successful_push_at"),
                lastSuccessfulAckAt: try Self.date(fromSQLiteText: statement.optionalText(at: 9), field: "last_successful_ack_at"),
                lastAppleScanStartedAt: try Self.date(fromSQLiteText: statement.optionalText(at: 10), field: "last_apple_scan_started_at"),
                lastSyncStatus: statement.optionalText(at: 11),
                lastErrorCode: statement.optionalText(at: 12),
                lastErrorMessage: statement.optionalText(at: 13)
            )
        }
    }

    public func saveCheckpoint(_ checkpoint: SyncCheckpoint) async throws {
        try withDatabase { database in
            let now = Self.iso8601String(from: Date()) ?? ""
            let sql = """
            INSERT INTO sync_checkpoint (
                id,
                backend_cursor,
                last_pull_cursor,
                last_push_cursor,
                last_acked_change_id,
                last_failed_change_id,
                last_seen_change_id,
                last_successful_sync_at,
                last_successful_pull_at,
                last_successful_push_at,
                last_successful_ack_at,
                last_apple_scan_started_at,
                last_sync_status,
                last_error_code,
                last_error_message,
                updated_at
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                backend_cursor = excluded.backend_cursor,
                last_pull_cursor = excluded.last_pull_cursor,
                last_push_cursor = excluded.last_push_cursor,
                last_acked_change_id = excluded.last_acked_change_id,
                last_failed_change_id = excluded.last_failed_change_id,
                last_seen_change_id = excluded.last_seen_change_id,
                last_successful_sync_at = excluded.last_successful_sync_at,
                last_successful_pull_at = excluded.last_successful_pull_at,
                last_successful_push_at = excluded.last_successful_push_at,
                last_successful_ack_at = excluded.last_successful_ack_at,
                last_apple_scan_started_at = excluded.last_apple_scan_started_at,
                last_sync_status = excluded.last_sync_status,
                last_error_code = excluded.last_error_code,
                last_error_message = excluded.last_error_message,
                updated_at = excluded.updated_at;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }
            statement.bind(optionalText: checkpoint.backendCursor, at: 1)
            statement.bind(optionalText: checkpoint.lastPullCursor, at: 2)
            statement.bind(optionalText: checkpoint.lastPushCursor, at: 3)
            statement.bind(optionalInt: checkpoint.lastAckedChangeID, at: 4)
            statement.bind(optionalInt: checkpoint.lastFailedChangeID, at: 5)
            statement.bind(optionalInt: checkpoint.lastSeenChangeID, at: 6)
            statement.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulSyncAt), at: 7)
            statement.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulPullAt), at: 8)
            statement.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulPushAt), at: 9)
            statement.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulAckAt), at: 10)
            statement.bind(optionalText: Self.iso8601String(from: checkpoint.lastAppleScanStartedAt), at: 11)
            statement.bind(optionalText: checkpoint.lastSyncStatus, at: 12)
            statement.bind(optionalText: checkpoint.lastErrorCode, at: 13)
            statement.bind(optionalText: checkpoint.lastErrorMessage, at: 14)
            statement.bind(text: now, at: 15)
            try statement.runToCompletion()
        }
    }

    public func loadMappings() async throws -> [ReminderTaskMapping] {
        try withDatabase { database in
            let sql = """
            SELECT reminder_id,
                   task_id,
                   reminder_external_identifier,
                   reminder_list_identifier,
                   reminder_fingerprint,
                   backend_version_token,
                   sync_state,
                   synced_at
            FROM reminder_task_mappings
            ORDER BY reminder_id ASC;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            var mappings: [ReminderTaskMapping] = []
            while statement.step() == .row {
                guard let reminderID = statement.text(at: 0), !reminderID.isEmpty,
                      let taskID = statement.text(at: 1), !taskID.isEmpty,
                      let fingerprint = statement.text(at: 4), !fingerprint.isEmpty,
                      let versionToken = statement.text(at: 5), !versionToken.isEmpty,
                      let syncStateText = statement.text(at: 6),
                      let syncState = SyncEntityState(rawValue: syncStateText),
                      let syncedAtText = statement.text(at: 7) else {
                    throw SQLiteBridgeStateStoreError.invalidMapping("missing required mapping columns")
                }

                let syncedAt = try Self.date(fromSQLiteRequiredText: syncedAtText, field: "synced_at")
                mappings.append(
                    ReminderTaskMapping(
                        reminderID: reminderID,
                        taskID: taskID,
                        reminderExternalIdentifier: statement.optionalText(at: 2),
                        reminderListIdentifier: statement.optionalText(at: 3),
                        reminderFingerprint: ReminderFingerprint(value: fingerprint),
                        backendVersionToken: versionToken,
                        syncState: syncState,
                        syncedAt: syncedAt
                    )
                )
            }
            return mappings
        }
    }

    public func saveMappings(_ mappings: [ReminderTaskMapping]) async throws {
        guard !mappings.isEmpty else { return }
        try withDatabase { database in
            try database.beginTransaction()
            defer { try? database.commitIfNeeded() }

            let sql = """
            INSERT INTO reminder_task_mappings (
                reminder_id,
                task_id,
                reminder_external_identifier,
                reminder_list_identifier,
                reminder_fingerprint,
                backend_version_token,
                sync_state,
                synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(reminder_id) DO UPDATE SET
                task_id = excluded.task_id,
                reminder_external_identifier = excluded.reminder_external_identifier,
                reminder_list_identifier = excluded.reminder_list_identifier,
                reminder_fingerprint = excluded.reminder_fingerprint,
                backend_version_token = excluded.backend_version_token,
                sync_state = excluded.sync_state,
                synced_at = excluded.synced_at;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            for mapping in mappings {
                statement.reset()
                statement.clearBindings()
                statement.bind(text: mapping.reminderID, at: 1)
                statement.bind(text: mapping.taskID, at: 2)
                statement.bind(optionalText: mapping.reminderExternalIdentifier, at: 3)
                statement.bind(optionalText: mapping.reminderListIdentifier, at: 4)
                statement.bind(text: mapping.reminderFingerprint.value, at: 5)
                statement.bind(text: mapping.backendVersionToken, at: 6)
                statement.bind(text: mapping.syncState.rawValue, at: 7)
                statement.bind(text: Self.iso8601String(from: mapping.syncedAt) ?? "", at: 8)
                try statement.runToCompletion()
            }

            try database.commitTransaction()
        }
    }

    public func loadPendingOperations() async throws -> [PendingOperation] {
        try withDatabase { database in
            let sql = """
            SELECT id,
                   kind,
                   entity_id,
                   payload,
                   status,
                   last_error_message,
                   attempt_count,
                   next_retry_at,
                   created_at,
                   updated_at
            FROM pending_operations
            ORDER BY COALESCE(next_retry_at, '9999-12-31T23:59:59Z') ASC, created_at ASC;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            var operations: [PendingOperation] = []
            while statement.step() == .row {
                guard let idText = statement.text(at: 0),
                      let id = UUID(uuidString: idText),
                      let kindText = statement.text(at: 1),
                      let kind = OperationKind(rawValue: kindText),
                      let entityID = statement.text(at: 2),
                      let statusText = statement.text(at: 4),
                      let status = OperationStatus(rawValue: statusText),
                      let createdAtText = statement.text(at: 8),
                      let updatedAtText = statement.text(at: 9) else {
                    throw SQLiteBridgeStateStoreError.invalidPendingOperation("missing required pending operation columns")
                }

                operations.append(
                    PendingOperation(
                        id: id,
                        kind: kind,
                        entityID: entityID,
                        payload: statement.blob(at: 3),
                        status: status,
                        lastErrorMessage: statement.optionalText(at: 5),
                        attemptCount: Int(statement.int64(at: 6)),
                        nextRetryAt: try Self.date(fromSQLiteText: statement.optionalText(at: 7), field: "next_retry_at"),
                        createdAt: try Self.date(fromSQLiteRequiredText: createdAtText, field: "created_at"),
                        updatedAt: try Self.date(fromSQLiteRequiredText: updatedAtText, field: "updated_at")
                    )
                )
            }
            return operations
        }
    }

    public func enqueuePendingOperations(_ operations: [PendingOperation]) async throws {
        try await upsertPendingOperations(operations)
    }

    public func updatePendingOperations(_ operations: [PendingOperation]) async throws {
        try await upsertPendingOperations(operations)
    }

    public func removePendingOperations(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try withDatabase { database in
            try database.beginTransaction()
            defer { try? database.commitIfNeeded() }

            let sql = "DELETE FROM pending_operations WHERE id = ?;"
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            for id in ids {
                statement.reset()
                statement.clearBindings()
                statement.bind(text: id.uuidString.lowercased(), at: 1)
                try statement.runToCompletion()
            }

            try database.commitTransaction()
        }
    }

    public nonisolated func exportSQLiteSchema() -> SQLiteSchemaDefinition {
        schemaDefinition
    }

    private func migrateIfNeeded() async throws {
        try withDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode=WAL;")
            try database.execute(sql: "PRAGMA foreign_keys=ON;")
            for statement in schemaDefinition.createStatements {
                try database.execute(sql: statement)
            }

            let checkSQL = "SELECT COUNT(*) FROM schema_migrations WHERE version = ?;"
            let checkStatement = try database.prepare(sql: checkSQL)
            defer { checkStatement.finalize() }
            checkStatement.bind(int64: Int64(schemaDefinition.currentVersion), at: 1)

            let hasVersion: Bool
            if checkStatement.step() == .row {
                hasVersion = checkStatement.int64(at: 0) > 0
            } else {
                hasVersion = false
            }

            if !hasVersion {
                let insertSQL = "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);"
                let insertStatement = try database.prepare(sql: insertSQL)
                defer { insertStatement.finalize() }
                insertStatement.bind(int64: Int64(schemaDefinition.currentVersion), at: 1)
                insertStatement.bind(text: Self.iso8601String(from: Date()) ?? "", at: 2)
                try insertStatement.runToCompletion()
            }
        }
    }

    private func seedDefaultsIfNeeded() async throws {
        try await saveConfigurationIfMissing(defaultConfiguration)
        try await saveCheckpointIfMissing(.init())
    }

    private func saveConfigurationIfMissing(_ configuration: BridgeConfiguration) async throws {
        try withDatabase { database in
            let checkStatement = try database.prepare(sql: "SELECT COUNT(*) FROM bridge_configuration WHERE id = 1;")
            defer { checkStatement.finalize() }
            let count = checkStatement.step() == .row ? checkStatement.int64(at: 0) : 0
            guard count == 0 else { return }

            let now = Self.iso8601String(from: Date()) ?? ""
            let insert = try database.prepare(sql: "INSERT INTO bridge_configuration (id, backend_base_url, api_token, sync_interval_seconds, default_reminder_list_identifier, updated_at) VALUES (1, ?, ?, ?, ?, ?);")
            defer { insert.finalize() }
            insert.bind(text: configuration.backendBaseURL.absoluteString, at: 1)
            insert.bind(optionalText: configuration.apiToken, at: 2)
            insert.bind(double: configuration.syncIntervalSeconds, at: 3)
            insert.bind(optionalText: configuration.defaultReminderListIdentifier, at: 4)
            insert.bind(text: now, at: 5)
            try insert.runToCompletion()
        }
    }

    private func saveCheckpointIfMissing(_ checkpoint: SyncCheckpoint) async throws {
        try withDatabase { database in
            let checkStatement = try database.prepare(sql: "SELECT COUNT(*) FROM sync_checkpoint WHERE id = 1;")
            defer { checkStatement.finalize() }
            let count = checkStatement.step() == .row ? checkStatement.int64(at: 0) : 0
            guard count == 0 else { return }

            let now = Self.iso8601String(from: Date()) ?? ""
            let insert = try database.prepare(sql: "INSERT INTO sync_checkpoint (id, backend_cursor, last_pull_cursor, last_push_cursor, last_acked_change_id, last_failed_change_id, last_seen_change_id, last_successful_sync_at, last_successful_pull_at, last_successful_push_at, last_successful_ack_at, last_apple_scan_started_at, last_sync_status, last_error_code, last_error_message, updated_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
            defer { insert.finalize() }
            insert.bind(optionalText: checkpoint.backendCursor, at: 1)
            insert.bind(optionalText: checkpoint.lastPullCursor, at: 2)
            insert.bind(optionalText: checkpoint.lastPushCursor, at: 3)
            insert.bind(optionalInt: checkpoint.lastAckedChangeID, at: 4)
            insert.bind(optionalInt: checkpoint.lastFailedChangeID, at: 5)
            insert.bind(optionalInt: checkpoint.lastSeenChangeID, at: 6)
            insert.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulSyncAt), at: 7)
            insert.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulPullAt), at: 8)
            insert.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulPushAt), at: 9)
            insert.bind(optionalText: Self.iso8601String(from: checkpoint.lastSuccessfulAckAt), at: 10)
            insert.bind(optionalText: Self.iso8601String(from: checkpoint.lastAppleScanStartedAt), at: 11)
            insert.bind(optionalText: checkpoint.lastSyncStatus, at: 12)
            insert.bind(optionalText: checkpoint.lastErrorCode, at: 13)
            insert.bind(optionalText: checkpoint.lastErrorMessage, at: 14)
            insert.bind(text: now, at: 15)
            try insert.runToCompletion()
        }
    }

    private func upsertPendingOperations(_ operations: [PendingOperation]) async throws {
        guard !operations.isEmpty else { return }
        try withDatabase { database in
            try database.beginTransaction()
            defer { try? database.commitIfNeeded() }

            let sql = """
            INSERT INTO pending_operations (
                id,
                kind,
                entity_id,
                payload,
                status,
                last_error_message,
                attempt_count,
                next_retry_at,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                entity_id = excluded.entity_id,
                payload = excluded.payload,
                status = excluded.status,
                last_error_message = excluded.last_error_message,
                attempt_count = excluded.attempt_count,
                next_retry_at = excluded.next_retry_at,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """
            let statement = try database.prepare(sql: sql)
            defer { statement.finalize() }

            for operation in operations {
                statement.reset()
                statement.clearBindings()
                statement.bind(text: operation.id.uuidString.lowercased(), at: 1)
                statement.bind(text: operation.kind.rawValue, at: 2)
                statement.bind(text: operation.entityID, at: 3)
                statement.bind(blob: operation.payload, at: 4)
                statement.bind(text: operation.status.rawValue, at: 5)
                statement.bind(optionalText: operation.lastErrorMessage, at: 6)
                statement.bind(int64: Int64(operation.attemptCount), at: 7)
                statement.bind(optionalText: Self.iso8601String(from: operation.nextRetryAt), at: 8)
                statement.bind(text: Self.iso8601String(from: operation.createdAt) ?? "", at: 9)
                statement.bind(text: Self.iso8601String(from: operation.updatedAt) ?? "", at: 10)
                try statement.runToCompletion()
            }

            try database.commitTransaction()
        }
    }

    private func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        let database = try SQLiteDatabase(path: databaseURL.path)
        defer { database.close() }
        return try body(database)
    }

    public static func defaultJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func defaultJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func iso8601String(from date: Date?) -> String? {
        guard let date else { return nil }
        return iso8601Formatter.string(from: date)
    }

    private static func date(fromSQLiteText value: String?, field: String) throws -> Date? {
        guard let value else { return nil }
        return try date(fromSQLiteRequiredText: value, field: field)
    }

    private static func date(fromSQLiteRequiredText value: String, field: String) throws -> Date {
        guard let date = iso8601Formatter.date(from: value) else {
            throw SQLiteBridgeStateStoreError.invalidCheckpoint("failed to parse date field \(field)=\(value)")
        }
        return date
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public actor InMemoryBridgeStateStore: @preconcurrency BridgeStateStore {
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

    public nonisolated func exportSQLiteSchema() -> SQLiteSchemaDefinition {
        schemaDefinition
    }
}

#if canImport(SQLite3)
private final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var isInsideTransaction = false
    private let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(path, &handle, flags, nil)
        guard openResult == SQLITE_OK, handle != nil else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteBridgeStateStoreError.openDatabaseFailed(path: path, code: openResult, message: message)
        }
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    func execute(sql: String) throws {
        guard let handle else { throw SQLiteBridgeStateStoreError.sqliteUnavailable }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteBridgeStateStoreError.executeFailed(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func prepare(sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteBridgeStateStoreError.sqliteUnavailable }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteBridgeStateStoreError.prepareFailed(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: handle, statement: statement, sql: sql)
    }

    func beginTransaction() throws {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        isInsideTransaction = true
    }

    func commitTransaction() throws {
        try execute(sql: "COMMIT;")
        isInsideTransaction = false
    }

    func commitIfNeeded() throws {
        if isInsideTransaction {
            try commitTransaction()
        }
    }
}

private final class SQLiteStatement {
    enum StepResult {
        case row
        case done
    }

    private let handle: OpaquePointer
    private let statement: OpaquePointer
    private let sql: String

    init(handle: OpaquePointer, statement: OpaquePointer, sql: String) {
        self.handle = handle
        self.statement = statement
        self.sql = sql
    }

    func finalize() {
        sqlite3_finalize(statement)
    }

    func reset() {
        sqlite3_reset(statement)
    }

    func clearBindings() {
        sqlite3_clear_bindings(statement)
    }

    func bind(text: String, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    func bind(optionalText value: String?, at index: Int32) {
        if let value {
            bind(text: value, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(double: Double, at index: Int32) {
        sqlite3_bind_double(statement, index, double)
    }

    func bind(int64: Int64, at index: Int32) {
        sqlite3_bind_int64(statement, index, int64)
    }

    func bind(optionalInt: Int?, at index: Int32) {
        if let value = optionalInt {
            bind(int64: Int64(value), at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(blob value: Data?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        value.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                sqlite3_bind_blob(statement, index, baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
    }

    func step() -> StepResult {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return .row
        default:
            return .done
        }
    }

    func runToCompletion() throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteBridgeStateStoreError.stepFailed(sql: sql, code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func text(at index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func optionalText(at index: Int32) -> String? {
        text(at: index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func optionalInt(at index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(int64(at: index))
    }

    func blob(at index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif
