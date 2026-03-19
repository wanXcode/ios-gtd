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

public struct SyncCoordinatorDependencies: Sendable {
    public let reminderStore: any ReminderStore
    public let backendClient: any BackendSyncClient
    public let bridgeStore: any BridgeStateStore
    public let conflictResolver: any ConflictResolving
    public let retryScheduler: any RetryScheduling
    public let dateProvider: any DateProviding

    public init(
        reminderStore: any ReminderStore,
        backendClient: any BackendSyncClient,
        bridgeStore: any BridgeStateStore,
        conflictResolver: any ConflictResolving,
        retryScheduler: any RetryScheduling,
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.reminderStore = reminderStore
        self.backendClient = backendClient
        self.bridgeStore = bridgeStore
        self.conflictResolver = conflictResolver
        self.retryScheduler = retryScheduler
        self.dateProvider = dateProvider
    }
}
