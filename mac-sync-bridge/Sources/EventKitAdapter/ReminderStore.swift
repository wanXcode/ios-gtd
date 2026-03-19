import BridgeModels
import Foundation

public protocol ReminderStore: Sendable {
    func authorizationStatus() async throws -> ReminderAuthorizationStatus
    func requestAccessIfNeeded() async throws -> ReminderAuthorizationStatus
    func fetchReminders() async throws -> [ReminderRecord]
    func upsert(reminders: [ReminderRecord]) async throws
    func delete(reminders: [ReminderRecord]) async throws
}

public enum ReminderAuthorizationStatus: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

public actor InMemoryReminderStore: ReminderStore {
    private var authorization: ReminderAuthorizationStatus
    private var storage: [String: ReminderRecord]

    public init(
        authorization: ReminderAuthorizationStatus = .authorized,
        reminders: [ReminderRecord] = []
    ) {
        self.authorization = authorization
        self.storage = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
    }

    public func authorizationStatus() async throws -> ReminderAuthorizationStatus {
        authorization
    }

    public func requestAccessIfNeeded() async throws -> ReminderAuthorizationStatus {
        if authorization == .notDetermined {
            authorization = .authorized
        }
        return authorization
    }

    public func fetchReminders() async throws -> [ReminderRecord] {
        storage.values.sorted { $0.lastModifiedAt < $1.lastModifiedAt }
    }

    public func upsert(reminders: [ReminderRecord]) async throws {
        for reminder in reminders {
            storage[reminder.id] = reminder
        }
    }

    public func delete(reminders: [ReminderRecord]) async throws {
        for reminder in reminders {
            storage.removeValue(forKey: reminder.id)
        }
    }
}
