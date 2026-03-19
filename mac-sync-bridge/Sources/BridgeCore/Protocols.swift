import BridgeModels
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence

public protocol DateProviding: Sendable {
    func now() -> Date
}

public struct SystemDateProvider: DateProviding {
    public init() {}

    public func now() -> Date { Date() }
}

public protocol ConflictResolving: Sendable {
    func resolve(reminder: ReminderRecord, backendTask: BackendTaskRecord) -> ConflictResolutionStrategy
}

public struct LastWriteWinsConflictResolver: ConflictResolving {
    public init() {}

    public func resolve(reminder: ReminderRecord, backendTask: BackendTaskRecord) -> ConflictResolutionStrategy {
        reminder.lastModifiedAt >= backendTask.updatedAt ? .reminderWins : .backendWins
    }
}

public protocol RetryScheduling: Sendable {
    func nextRetryDate(for attemptCount: Int, from now: Date) -> Date
}

public struct ExponentialBackoffRetryScheduler: RetryScheduling {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 3600) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func nextRetryDate(for attemptCount: Int, from now: Date) -> Date {
        let exponent = max(0, attemptCount)
        let delay = min(baseDelay * pow(2, Double(exponent)), maxDelay)
        return now.addingTimeInterval(delay)
    }
}

public protocol PullPlanning: Sendable {
    func makePullPlan(context: PullPlanningContext, conflictResolver: any ConflictResolving) -> SyncPlan
}

public protocol PushPlanning: Sendable {
    func makePushMutations(context: PushPlanningContext) -> [PushTaskMutation]
}

public protocol PendingOperationExecuting: Sendable {
    func execute(_ operations: [PendingOperation], now: Date) async throws -> PendingExecutionResult
}

public struct PendingExecutionResult: Sendable {
    public var completedIDs: [UUID]
    public var updatedOperations: [PendingOperation]

    public init(completedIDs: [UUID] = [], updatedOperations: [PendingOperation] = []) {
        self.completedIDs = completedIDs
        self.updatedOperations = updatedOperations
    }
}

public actor NoopPendingOperationExecutor: PendingOperationExecuting {
    public init() {}

    public func execute(_ operations: [PendingOperation], now: Date) async throws -> PendingExecutionResult {
        _ = now
        return PendingExecutionResult(updatedOperations: operations)
    }
}

public actor DefaultPendingOperationExecutor: PendingOperationExecuting {
    private let backendClient: any BackendSyncClient
    private let retryScheduler: any RetryScheduling
    private let encoder: JSONEncoder

    public init(
        backendClient: any BackendSyncClient,
        retryScheduler: any RetryScheduling,
        encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()
    ) {
        self.backendClient = backendClient
        self.retryScheduler = retryScheduler
        self.encoder = encoder
    }

    public func execute(_ operations: [PendingOperation], now: Date) async throws -> PendingExecutionResult {
        var completedIDs: [UUID] = []
        var updated: [PendingOperation] = []

        for operation in operations {
            if let nextRetryAt = operation.nextRetryAt, nextRetryAt > now {
                updated.append(operation)
                continue
            }

            guard operation.kind == .createRemoteTask || operation.kind == .updateRemoteTask || operation.kind == .deleteRemoteTask else {
                updated.append(operation)
                continue
            }

            guard let payload = operation.payload else {
                updated.append(markFailed(operation: operation, now: now, message: "missing_payload", retryable: false))
                continue
            }

            do {
                let mutation = try JSONDecoder.bridgeModelsDecoder.decode(PushTaskMutation.self, from: payload)
                let response = try await backendClient.pushChanges(
                    request: PushChangesRequest(
                        bridgeID: "pending-replay",
                        tasks: [mutation],
                        limit: 1
                    )
                )
                let rejected = Set(response.rejectedReminderIDs)
                if rejected.contains(mutation.reminderID) {
                    updated.append(markFailed(operation: operation, now: now, message: "push_rejected", retryable: true))
                } else {
                    completedIDs.append(operation.id)
                }
            } catch {
                updated.append(markFailed(operation: operation, now: now, message: String(describing: error), retryable: true))
            }
        }

        return PendingExecutionResult(completedIDs: completedIDs, updatedOperations: updated)
    }

    private func markFailed(operation: PendingOperation, now: Date, message: String, retryable: Bool) -> PendingOperation {
        let nextAttempt = operation.attemptCount + 1
        return PendingOperation(
            id: operation.id,
            kind: operation.kind,
            entityID: operation.entityID,
            payload: operation.payload,
            status: retryable ? .retrying : .failed,
            lastErrorMessage: message,
            attemptCount: nextAttempt,
            nextRetryAt: retryable ? retryScheduler.nextRetryDate(for: nextAttempt, from: now) : nil,
            createdAt: operation.createdAt,
            updatedAt: now
        )
    }

}

public struct DefaultPullPlanner: PullPlanning {
    public init() {}

    public func makePullPlan(context: PullPlanningContext, conflictResolver: any ConflictResolving) -> SyncPlan {
        var plan = SyncPlan()

        for task in context.backendChanges {
            if let mapping = context.mappingByTaskID[task.id], let reminder = context.reminderByID[mapping.reminderID] {
                let reminderChanged = reminder.fingerprint != mapping.reminderFingerprint
                let backendChanged = task.versionToken != mapping.backendVersionToken

                if reminderChanged && backendChanged {
                    let resolution = conflictResolver.resolve(reminder: reminder, backendTask: task)
                    plan.conflicts.append(SyncConflict(reminder: reminder, backendTask: task, resolution: resolution))
                    switch resolution {
                    case .backendWins, .lastWriteWins:
                        if let resolved = reminderRecord(from: task, existingReminderID: reminder.id, externalIdentifier: reminder.externalIdentifier) {
                            if task.state == .deleted {
                                plan.localDeletes.append(resolved)
                            } else {
                                plan.localUpserts.append(resolved)
                            }
                        }
                        plan.ackTaskIDs.append(task.id)
                    case .reminderWins:
                        plan.remoteMutations.append(pushMutation(from: reminder, mappedTaskID: task.id, mapping: mapping))
                    case .manualReview:
                        break
                    }
                } else if backendChanged {
                    if let resolved = reminderRecord(from: task, existingReminderID: reminder.id, externalIdentifier: reminder.externalIdentifier) {
                        if task.state == .deleted {
                            plan.localDeletes.append(resolved)
                        } else {
                            plan.localUpserts.append(resolved)
                        }
                    }
                    plan.ackTaskIDs.append(task.id)
                }
            } else if let newReminder = reminderRecord(from: task, existingReminderID: UUID().uuidString, externalIdentifier: task.sourceRecordID ?? UUID().uuidString) {
                if task.state == .deleted {
                    continue
                }
                plan.localUpserts.append(newReminder)
                plan.ackTaskIDs.append(task.id)
            }
        }

        return plan
    }

    private func reminderRecord(from task: BackendTaskRecord, existingReminderID: String, externalIdentifier: String) -> ReminderRecord? {
        ReminderRecord(
            id: existingReminderID,
            externalIdentifier: externalIdentifier,
            title: task.title,
            notes: task.notes,
            dueDate: task.dueDate,
            isCompleted: task.state == .completed,
            isDeleted: task.state == .deleted,
            listIdentifier: task.sourceListID,
            lastModifiedAt: task.updatedAt,
            fingerprint: ReminderFingerprint(value: task.versionToken)
        )
    }

    private func pushMutation(from reminder: ReminderRecord, mappedTaskID: String?, mapping: ReminderTaskMapping?) -> PushTaskMutation {
        PushTaskMutation(
            taskID: mappedTaskID,
            reminderID: reminder.id,
            title: reminder.title,
            notes: reminder.notes,
            dueDate: reminder.dueDate,
            remindAt: nil,
            isAllDayDue: false,
            priority: nil,
            listName: nil,
            listIdentifier: reminder.listIdentifier,
            externalIdentifier: reminder.externalIdentifier,
            state: reminder.isDeleted ? .deleted : (reminder.isCompleted ? .completed : .active),
            fingerprint: reminder.fingerprint,
            lastModifiedAt: reminder.lastModifiedAt,
            backendVersionToken: mapping?.backendVersionToken,
            backendChangeID: nil
        )
    }
}

public struct DefaultPushPlanner: PushPlanning {
    public init() {}

    public func makePushMutations(context: PushPlanningContext) -> [PushTaskMutation] {
        var remoteMutations: [PushTaskMutation] = []

        for reminder in context.reminders {
            if let mapping = context.mappingByReminderID[reminder.id] {
                let fingerprintChanged = reminder.fingerprint != mapping.reminderFingerprint
                if fingerprintChanged {
                    remoteMutations.append(
                        PushTaskMutation(
                            taskID: mapping.taskID,
                            reminderID: reminder.id,
                            title: reminder.title,
                            notes: reminder.notes,
                            dueDate: reminder.dueDate,
                            remindAt: nil,
                            isAllDayDue: false,
                            priority: nil,
                            listName: nil,
                            listIdentifier: reminder.listIdentifier,
                            externalIdentifier: reminder.externalIdentifier,
                            state: reminder.isDeleted ? .deleted : (reminder.isCompleted ? .completed : .active),
                            fingerprint: reminder.fingerprint,
                            lastModifiedAt: reminder.lastModifiedAt,
                            backendVersionToken: mapping.backendVersionToken,
                            backendChangeID: nil
                        )
                    )
                }
            } else if !reminder.isDeleted {
                remoteMutations.append(
                    PushTaskMutation(
                        taskID: nil,
                        reminderID: reminder.id,
                        title: reminder.title,
                        notes: reminder.notes,
                        dueDate: reminder.dueDate,
                        remindAt: nil,
                        isAllDayDue: false,
                        priority: nil,
                        listName: nil,
                        listIdentifier: reminder.listIdentifier,
                        externalIdentifier: reminder.externalIdentifier,
                        state: reminder.isCompleted ? .completed : .active,
                        fingerprint: reminder.fingerprint,
                        lastModifiedAt: reminder.lastModifiedAt
                    )
                )
            }
        }

        return remoteMutations
    }
}

public struct SyncCoordinatorDependencies: Sendable {
    public let reminderStore: any ReminderStore
    public let backendClient: any BackendSyncClient
    public let bridgeStore: any BridgeStateStore
    public let conflictResolver: any ConflictResolving
    public let retryScheduler: any RetryScheduling
    public let dateProvider: any DateProviding
    public let pullPlanner: any PullPlanning
    public let pushPlanner: any PushPlanning
    public let pendingExecutor: any PendingOperationExecuting
    public let bridgeID: String

    public init(
        reminderStore: any ReminderStore,
        backendClient: any BackendSyncClient,
        bridgeStore: any BridgeStateStore,
        conflictResolver: any ConflictResolving,
        retryScheduler: any RetryScheduling,
        dateProvider: any DateProviding = SystemDateProvider(),
        pullPlanner: any PullPlanning = DefaultPullPlanner(),
        pushPlanner: any PushPlanning = DefaultPushPlanner(),
        pendingExecutor: (any PendingOperationExecuting)? = nil,
        bridgeID: String = ProcessInfo.processInfo.hostName
    ) {
        self.reminderStore = reminderStore
        self.backendClient = backendClient
        self.bridgeStore = bridgeStore
        self.conflictResolver = conflictResolver
        self.retryScheduler = retryScheduler
        self.dateProvider = dateProvider
        self.pullPlanner = pullPlanner
        self.pushPlanner = pushPlanner
        self.pendingExecutor = pendingExecutor ?? DefaultPendingOperationExecutor(
            backendClient: backendClient,
            retryScheduler: retryScheduler
        )
        self.bridgeID = bridgeID
    }
}

private extension JSONDecoder {
    static let bridgeModelsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
