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

public enum OperationStatus: String, Codable, Sendable {
    case pending
    case retrying
    case failed
    case completed
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
    public var remindAt: Date?
    public var isAllDayDue: Bool
    public var priority: Int?
    public var listName: String?
    public var state: SyncEntityState
    public var updatedAt: Date
    public var deletedAt: Date?
    public var versionToken: String
    public var changeID: Int?
    public var sourceRecordID: String?
    public var sourceListID: String?
    public var sourceCalendarID: String?

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        remindAt: Date? = nil,
        isAllDayDue: Bool = false,
        priority: Int? = nil,
        listName: String? = nil,
        state: SyncEntityState,
        updatedAt: Date,
        deletedAt: Date? = nil,
        versionToken: String,
        changeID: Int? = nil,
        sourceRecordID: String? = nil,
        sourceListID: String? = nil,
        sourceCalendarID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.remindAt = remindAt
        self.isAllDayDue = isAllDayDue
        self.priority = priority
        self.listName = listName
        self.state = state
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.versionToken = versionToken
        self.changeID = changeID
        self.sourceRecordID = sourceRecordID
        self.sourceListID = sourceListID
        self.sourceCalendarID = sourceCalendarID
    }
}

public struct ReminderTaskMapping: Codable, Hashable, Sendable {
    public let reminderID: String
    public let taskID: String
    public var reminderExternalIdentifier: String?
    public var reminderListIdentifier: String?
    public var reminderFingerprint: ReminderFingerprint
    public var backendVersionToken: String
    public var syncState: SyncEntityState
    public var syncedAt: Date

    public init(
        reminderID: String,
        taskID: String,
        reminderExternalIdentifier: String? = nil,
        reminderListIdentifier: String? = nil,
        reminderFingerprint: ReminderFingerprint,
        backendVersionToken: String,
        syncState: SyncEntityState = .active,
        syncedAt: Date
    ) {
        self.reminderID = reminderID
        self.taskID = taskID
        self.reminderExternalIdentifier = reminderExternalIdentifier
        self.reminderListIdentifier = reminderListIdentifier
        self.reminderFingerprint = reminderFingerprint
        self.backendVersionToken = backendVersionToken
        self.syncState = syncState
        self.syncedAt = syncedAt
    }
}

public struct SyncCheckpoint: Codable, Hashable, Sendable {
    public var backendCursor: String?
    public var lastPullCursor: String?
    public var lastPushCursor: String?
    public var lastAckedChangeID: Int?
    public var lastFailedChangeID: Int?
    public var lastSeenChangeID: Int?
    public var lastSuccessfulSyncAt: Date?
    public var lastSuccessfulPullAt: Date?
    public var lastSuccessfulPushAt: Date?
    public var lastSuccessfulAckAt: Date?
    public var lastAppleScanStartedAt: Date?
    public var lastSyncStatus: String?
    public var lastErrorCode: String?
    public var lastErrorMessage: String?

    public init(
        backendCursor: String? = nil,
        lastPullCursor: String? = nil,
        lastPushCursor: String? = nil,
        lastAckedChangeID: Int? = nil,
        lastFailedChangeID: Int? = nil,
        lastSeenChangeID: Int? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        lastSuccessfulPullAt: Date? = nil,
        lastSuccessfulPushAt: Date? = nil,
        lastSuccessfulAckAt: Date? = nil,
        lastAppleScanStartedAt: Date? = nil,
        lastSyncStatus: String? = nil,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.backendCursor = backendCursor
        self.lastPullCursor = lastPullCursor
        self.lastPushCursor = lastPushCursor
        self.lastAckedChangeID = lastAckedChangeID
        self.lastFailedChangeID = lastFailedChangeID
        self.lastSeenChangeID = lastSeenChangeID
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastSuccessfulPullAt = lastSuccessfulPullAt
        self.lastSuccessfulPushAt = lastSuccessfulPushAt
        self.lastSuccessfulAckAt = lastSuccessfulAckAt
        self.lastAppleScanStartedAt = lastAppleScanStartedAt
        self.lastSyncStatus = lastSyncStatus
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct PendingOperation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: OperationKind
    public let entityID: String
    public var payload: Data?
    public var status: OperationStatus
    public var lastErrorMessage: String?
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        entityID: String,
        payload: Data? = nil,
        status: OperationStatus = .pending,
        lastErrorMessage: String? = nil,
        attemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.payload = payload
        self.status = status
        self.lastErrorMessage = lastErrorMessage
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PullChangesRequest: Codable, Sendable {
    public var bridgeID: String
    public var cursor: String?
    public var limit: Int
    public var localChanges: [ApplePullChange]

    public init(
        bridgeID: String,
        cursor: String? = nil,
        limit: Int = 200,
        localChanges: [ApplePullChange] = []
    ) {
        self.bridgeID = bridgeID
        self.cursor = cursor
        self.limit = limit
        self.localChanges = localChanges
    }
}

public struct PullChangesResponse: Codable, Sendable {
    public var accepted: Int
    public var applied: Int
    public var changes: [BackendTaskRecord]
    public var nextCursor: String?
    public var backendCursor: String?
    public var hasMore: Bool

    public init(
        accepted: Int = 0,
        applied: Int = 0,
        changes: [BackendTaskRecord],
        nextCursor: String?,
        backendCursor: String? = nil,
        hasMore: Bool
    ) {
        self.accepted = accepted
        self.applied = applied
        self.changes = changes
        self.nextCursor = nextCursor
        self.backendCursor = backendCursor
        self.hasMore = hasMore
    }
}

public struct PushTaskMutation: Codable, Hashable, Sendable {
    public var taskID: String?
    public var reminderID: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var remindAt: Date?
    public var isAllDayDue: Bool
    public var priority: Int?
    public var listName: String?
    public var listIdentifier: String?
    public var externalIdentifier: String?
    public var state: SyncEntityState
    public var fingerprint: ReminderFingerprint
    public var lastModifiedAt: Date
    public var backendVersionToken: String?
    public var backendChangeID: Int?

    public init(
        taskID: String? = nil,
        reminderID: String,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        remindAt: Date? = nil,
        isAllDayDue: Bool = false,
        priority: Int? = nil,
        listName: String? = nil,
        listIdentifier: String? = nil,
        externalIdentifier: String? = nil,
        state: SyncEntityState,
        fingerprint: ReminderFingerprint,
        lastModifiedAt: Date,
        backendVersionToken: String? = nil,
        backendChangeID: Int? = nil
    ) {
        self.taskID = taskID
        self.reminderID = reminderID
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.remindAt = remindAt
        self.isAllDayDue = isAllDayDue
        self.priority = priority
        self.listName = listName
        self.listIdentifier = listIdentifier
        self.externalIdentifier = externalIdentifier
        self.state = state
        self.fingerprint = fingerprint
        self.lastModifiedAt = lastModifiedAt
        self.backendVersionToken = backendVersionToken
        self.backendChangeID = backendChangeID
    }
}

public struct PushChangesRequest: Codable, Sendable {
    public var bridgeID: String
    public var cursor: String?
    public var tasks: [PushTaskVersion]
    public var limit: Int

    public init(
        bridgeID: String,
        cursor: String? = nil,
        tasks: [PushTaskVersion] = [],
        limit: Int = 200
    ) {
        self.bridgeID = bridgeID
        self.cursor = cursor
        self.tasks = tasks
        self.limit = limit
    }
}

public struct PushTaskVersion: Codable, Hashable, Sendable {
    public var taskID: String
    public var version: Int

    public init(taskID: String, version: Int) {
        self.taskID = taskID
        self.version = version
    }
}

public struct PushTaskResult: Codable, Hashable, Sendable {
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
    public var items: [RemoteTaskEnvelope]
    public var nextCursor: String?
    public var hasMore: Bool

    public init(
        accepted: [PushTaskResult],
        rejectedReminderIDs: [String] = [],
        items: [RemoteTaskEnvelope] = [],
        nextCursor: String? = nil,
        hasMore: Bool = false
    ) {
        self.accepted = accepted
        self.rejectedReminderIDs = rejectedReminderIDs
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct AckRequest: Codable, Sendable {
    public var bridgeID: String
    public var acknowledgements: [AckItem]

    public init(bridgeID: String, acknowledgements: [AckItem]) {
        self.bridgeID = bridgeID
        self.acknowledgements = acknowledgements
    }
}

public struct AckItem: Codable, Hashable, Sendable {
    public var taskID: String
    public var remoteID: String?
    public var version: Int
    public var changeID: Int?
    public var status: String
    public var appleModifiedAt: Date?
    public var appleListID: String?
    public var appleCalendarID: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var retryable: Bool

    public init(
        taskID: String,
        remoteID: String? = nil,
        version: Int,
        changeID: Int? = nil,
        status: String = "success",
        appleModifiedAt: Date? = nil,
        appleListID: String? = nil,
        appleCalendarID: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        retryable: Bool = false
    ) {
        self.taskID = taskID
        self.remoteID = remoteID
        self.version = version
        self.changeID = changeID
        self.status = status
        self.appleModifiedAt = appleModifiedAt
        self.appleListID = appleListID
        self.appleCalendarID = appleCalendarID
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.retryable = retryable
    }
}

public struct ApplePullChange: Codable, Hashable, Sendable {
    public var changeType: String
    public var appleReminderID: String
    public var appleListID: String?
    public var appleCalendarID: String?
    public var appleModifiedAt: Date?
    public var payload: ApplePullChangePayload?

    public init(
        changeType: String,
        appleReminderID: String,
        appleListID: String? = nil,
        appleCalendarID: String? = nil,
        appleModifiedAt: Date? = nil,
        payload: ApplePullChangePayload? = nil
    ) {
        self.changeType = changeType
        self.appleReminderID = appleReminderID
        self.appleListID = appleListID
        self.appleCalendarID = appleCalendarID
        self.appleModifiedAt = appleModifiedAt
        self.payload = payload
    }
}

public struct ApplePullChangePayload: Codable, Hashable, Sendable {
    public var title: String
    public var note: String?
    public var isCompleted: Bool
    public var dueAt: Date?
    public var remindAt: Date?
    public var isAllDayDue: Bool
    public var priority: Int?
    public var listName: String?

    public init(
        title: String,
        note: String? = nil,
        isCompleted: Bool = false,
        dueAt: Date? = nil,
        remindAt: Date? = nil,
        isAllDayDue: Bool = false,
        priority: Int? = nil,
        listName: String? = nil
    ) {
        self.title = title
        self.note = note
        self.isCompleted = isCompleted
        self.dueAt = dueAt
        self.remindAt = remindAt
        self.isAllDayDue = isAllDayDue
        self.priority = priority
        self.listName = listName
    }
}

public struct RemoteTaskEnvelope: Codable, Hashable, Sendable {
    public var taskID: String
    public var version: Int
    public var changeID: Int?
    public var operation: String
    public var task: BackendTaskRecord

    public init(taskID: String, version: Int, changeID: Int? = nil, operation: String, task: BackendTaskRecord) {
        self.taskID = taskID
        self.version = version
        self.changeID = changeID
        self.operation = operation
        self.task = task
    }
}

public struct PullPlanningContext: Sendable {
    public var backendChanges: [BackendTaskRecord]
    public var reminderByID: [String: ReminderRecord]
    public var mappingByTaskID: [String: ReminderTaskMapping]

    public init(
        backendChanges: [BackendTaskRecord],
        reminderByID: [String: ReminderRecord],
        mappingByTaskID: [String: ReminderTaskMapping]
    ) {
        self.backendChanges = backendChanges
        self.reminderByID = reminderByID
        self.mappingByTaskID = mappingByTaskID
    }
}

public struct PushPlanningContext: Sendable {
    public var reminders: [ReminderRecord]
    public var mappingByReminderID: [String: ReminderTaskMapping]

    public init(
        reminders: [ReminderRecord],
        mappingByReminderID: [String: ReminderTaskMapping]
    ) {
        self.reminders = reminders
        self.mappingByReminderID = mappingByReminderID
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
    public var consumedPendingCount: Int

    public init(
        startedAt: Date,
        finishedAt: Date,
        pulledCount: Int,
        pushedCount: Int,
        ackedCount: Int,
        conflictCount: Int,
        queuedRetryCount: Int,
        consumedPendingCount: Int = 0
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pulledCount = pulledCount
        self.pushedCount = pushedCount
        self.ackedCount = ackedCount
        self.conflictCount = conflictCount
        self.queuedRetryCount = queuedRetryCount
        self.consumedPendingCount = consumedPendingCount
    }
}
