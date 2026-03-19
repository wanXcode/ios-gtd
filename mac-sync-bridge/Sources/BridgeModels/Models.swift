import Foundation

public enum SyncDirection: String, Codable, Sendable {
    case pull
    case push
    case bidirectional
}

public enum SyncEntityState: String, Codable, Sendable {
    case active
    case completed
    case deleted
}

public enum OperationKind: String, Codable, Sendable {
    case createRemoteTask
    case updateRemoteTask
    case deleteRemoteTask
    case createLocalReminder
    case updateLocalReminder
    case deleteLocalReminder
}

public enum ConflictResolutionStrategy: String, Codable, Sendable {
    case lastWriteWins
    case backendWins
    case reminderWins
    case manualReview
}

public struct ReminderFingerprint: Codable, Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public struct ReminderRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var externalIdentifier: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var isDeleted: Bool
    public var listIdentifier: String?
    public var lastModifiedAt: Date
    public var fingerprint: ReminderFingerprint

    public init(
        id: String,
        externalIdentifier: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        isDeleted: Bool = false,
        listIdentifier: String? = nil,
        lastModifiedAt: Date,
        fingerprint: ReminderFingerprint
    ) {
        self.id = id
        self.externalIdentifier = externalIdentifier
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.isDeleted = isDeleted
        self.listIdentifier = listIdentifier
        self.lastModifiedAt = lastModifiedAt
        self.fingerprint = fingerprint
    }
}

public struct BackendTaskRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var state: SyncEntityState
    public var updatedAt: Date
    public var deletedAt: Date?
    public var versionToken: String

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        state: SyncEntityState,
        updatedAt: Date,
        deletedAt: Date? = nil,
        versionToken: String
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.state = state
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.versionToken = versionToken
    }
}

public struct ReminderTaskMapping: Codable, Hashable, Sendable {
    public let reminderID: String
    public let taskID: String
    public var reminderFingerprint: ReminderFingerprint
    public var backendVersionToken: String
    public var syncedAt: Date

    public init(
        reminderID: String,
        taskID: String,
        reminderFingerprint: ReminderFingerprint,
        backendVersionToken: String,
        syncedAt: Date
    ) {
        self.reminderID = reminderID
        self.taskID = taskID
        self.reminderFingerprint = reminderFingerprint
        self.backendVersionToken = backendVersionToken
        self.syncedAt = syncedAt
    }
}

public struct SyncCheckpoint: Codable, Hashable, Sendable {
    public var backendCursor: String?
    public var lastSuccessfulSyncAt: Date?

    public init(backendCursor: String? = nil, lastSuccessfulSyncAt: Date? = nil) {
        self.backendCursor = backendCursor
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }
}

public struct PendingOperation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: OperationKind
    public let entityID: String
    public var payload: Data?
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        entityID: String,
        payload: Data? = nil,
        attemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.payload = payload
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PullChangesRequest: Codable, Sendable {
    public var cursor: String?
    public var limit: Int

    public init(cursor: String? = nil, limit: Int = 200) {
        self.cursor = cursor
        self.limit = limit
    }
}

public struct PullChangesResponse: Codable, Sendable {
    public var changes: [BackendTaskRecord]
    public var nextCursor: String?
    public var hasMore: Bool

    public init(changes: [BackendTaskRecord], nextCursor: String?, hasMore: Bool) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct PushTaskMutation: Codable, Sendable {
    public var taskID: String?
    public var reminderID: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var state: SyncEntityState
    public var fingerprint: ReminderFingerprint
    public var lastModifiedAt: Date

    public init(
        taskID: String? = nil,
        reminderID: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        state: SyncEntityState,
        fingerprint: ReminderFingerprint,
        lastModifiedAt: Date
    ) {
        self.taskID = taskID
        self.reminderID = reminderID
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.state = state
        self.fingerprint = fingerprint
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct PushChangesRequest: Codable, Sendable {
    public var changes: [PushTaskMutation]

    public init(changes: [PushTaskMutation]) {
        self.changes = changes
    }
}

public struct PushTaskResult: Codable, Sendable {
    public var reminderID: String
    public var task: BackendTaskRecord

    public init(reminderID: String, task: BackendTaskRecord) {
        self.reminderID = reminderID
        self.task = task
    }
}

public struct PushChangesResponse: Codable, Sendable {
    public var accepted: [PushTaskResult]
    public var rejectedReminderIDs: [String]

    public init(accepted: [PushTaskResult], rejectedReminderIDs: [String] = []) {
        self.accepted = accepted
        self.rejectedReminderIDs = rejectedReminderIDs
    }
}

public struct AckRequest: Codable, Sendable {
    public var taskIDs: [String]
    public var cursor: String?

    public init(taskIDs: [String], cursor: String? = nil) {
        self.taskIDs = taskIDs
        self.cursor = cursor
    }
}

public struct SyncPlan: Sendable {
    public var localUpserts: [ReminderRecord]
    public var localDeletes: [ReminderRecord]
    public var remoteMutations: [PushTaskMutation]
    public var ackTaskIDs: [String]
    public var conflicts: [SyncConflict]

    public init(
        localUpserts: [ReminderRecord] = [],
        localDeletes: [ReminderRecord] = [],
        remoteMutations: [PushTaskMutation] = [],
        ackTaskIDs: [String] = [],
        conflicts: [SyncConflict] = []
    ) {
        self.localUpserts = localUpserts
        self.localDeletes = localDeletes
        self.remoteMutations = remoteMutations
        self.ackTaskIDs = ackTaskIDs
        self.conflicts = conflicts
    }
}

public struct SyncConflict: Sendable {
    public var reminder: ReminderRecord
    public var backendTask: BackendTaskRecord
    public var resolution: ConflictResolutionStrategy

    public init(reminder: ReminderRecord, backendTask: BackendTaskRecord, resolution: ConflictResolutionStrategy) {
        self.reminder = reminder
        self.backendTask = backendTask
        self.resolution = resolution
    }
}

public struct SyncRunReport: Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var pulledCount: Int
    public var pushedCount: Int
    public var ackedCount: Int
    public var conflictCount: Int
    public var queuedRetryCount: Int

    public init(
        startedAt: Date,
        finishedAt: Date,
        pulledCount: Int,
        pushedCount: Int,
        ackedCount: Int,
        conflictCount: Int,
        queuedRetryCount: Int
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pulledCount = pulledCount
        self.pushedCount = pushedCount
        self.ackedCount = ackedCount
        self.conflictCount = conflictCount
        self.queuedRetryCount = queuedRetryCount
    }
}
