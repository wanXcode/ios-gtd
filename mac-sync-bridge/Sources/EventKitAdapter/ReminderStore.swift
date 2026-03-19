import BridgeModels
import Foundation
#if canImport(EventKit)
import EventKit
#endif

public protocol ReminderStore: Sendable {
    func authorizationStatus() async throws -> ReminderAuthorizationStatus
    func requestAccessIfNeeded() async throws -> ReminderAuthorizationStatus
    func fetchReminderLists() async throws -> [ReminderListRecord]
    func fetchReminders() async throws -> [ReminderRecord]
    func upsert(reminders: [ReminderRecord]) async throws
    func delete(reminders: [ReminderRecord]) async throws
}

public enum ReminderAuthorizationStatus: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum ReminderStoreError: Error, Sendable, LocalizedError {
    case accessDenied
    case reminderNotFound(String)
    case listNotFound(String)
    case eventKitUnavailable
    case eventKitFailure(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access denied"
        case let .reminderNotFound(identifier):
            return "Reminder not found: \(identifier)"
        case let .listNotFound(identifier):
            return "Reminder list not found: \(identifier)"
        case .eventKitUnavailable:
            return "EventKit is unavailable in this build environment"
        case let .eventKitFailure(message):
            return "EventKit operation failed: \(message)"
        }
    }
}

public struct EventKitReminderStoreConfiguration: Sendable {
    public var syncedListIdentifiers: Set<String>
    public var defaultListIdentifier: String?
    public var includeCompleted: Bool
    public var includeDeletedInferenceCandidates: Bool
    public var scanWindow: TimeInterval?
    public var dateProvider: @Sendable () -> Date

    public init(
        syncedListIdentifiers: Set<String> = [],
        defaultListIdentifier: String? = nil,
        includeCompleted: Bool = true,
        includeDeletedInferenceCandidates: Bool = false,
        scanWindow: TimeInterval? = nil,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.syncedListIdentifiers = syncedListIdentifiers
        self.defaultListIdentifier = defaultListIdentifier
        self.includeCompleted = includeCompleted
        self.includeDeletedInferenceCandidates = includeDeletedInferenceCandidates
        self.scanWindow = scanWindow
        self.dateProvider = dateProvider
    }
}

public struct ReminderListRecord: Codable, Hashable, Sendable {
    public var identifier: String
    public var title: String
    public var sourceIdentifier: String?
    public var allowsContentModifications: Bool

    public init(
        identifier: String,
        title: String,
        sourceIdentifier: String? = nil,
        allowsContentModifications: Bool = true
    ) {
        self.identifier = identifier
        self.title = title
        self.sourceIdentifier = sourceIdentifier
        self.allowsContentModifications = allowsContentModifications
    }
}

public protocol ReminderDTOConverting: Sendable {
    func fingerprint(
        title: String,
        notes: String?,
        dueDate: Date?,
        isCompleted: Bool,
        listIdentifier: String?
    ) -> ReminderFingerprint
}

public struct DefaultReminderDTOConverter: ReminderDTOConverting {
    public init() {}

    public func fingerprint(
        title: String,
        notes: String?,
        dueDate: Date?,
        isCompleted: Bool,
        listIdentifier: String?
    ) -> ReminderFingerprint {
        let payload = [
            title,
            notes ?? "",
            dueDate.map { Self.iso8601Formatter.string(from: $0) } ?? "",
            isCompleted ? "1" : "0",
            listIdentifier ?? ""
        ].joined(separator: "|")
        return ReminderFingerprint(value: payload)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

#if canImport(EventKit)
public protocol EventKitReminderStoreProtocol: ReminderStore {
    func fetchReminderLists() async throws -> [ReminderListRecord]
}

public actor EventKitReminderStore: EventKitReminderStoreProtocol {
    private let eventStore: EKEventStore
    private let configuration: EventKitReminderStoreConfiguration
    private let converter: any ReminderDTOConverting

    public init(
        eventStore: EKEventStore = EKEventStore(),
        configuration: EventKitReminderStoreConfiguration = .init(),
        converter: any ReminderDTOConverting = DefaultReminderDTOConverter()
    ) {
        self.eventStore = eventStore
        self.configuration = configuration
        self.converter = converter
    }

    public func authorizationStatus() async throws -> ReminderAuthorizationStatus {
        Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func requestAccessIfNeeded() async throws -> ReminderAuthorizationStatus {
        let current = try await authorizationStatus()
        if current == .authorized || current == .denied {
            return current
        }

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await eventStore.requestFullAccessToReminders()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: ReminderStoreError.eventKitFailure(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }

        return granted ? .authorized : .denied
    }

    public func fetchReminderLists() async throws -> [ReminderListRecord] {
        try await ensureAuthorized()
        return eventStore.calendars(for: .reminder)
            .filter(isCalendarEligible(_:))
            .map {
                ReminderListRecord(
                    identifier: $0.calendarIdentifier,
                    title: $0.title,
                    sourceIdentifier: $0.source.sourceIdentifier,
                    allowsContentModifications: $0.allowsContentModifications
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func fetchReminders() async throws -> [ReminderRecord] {
        try await ensureAuthorized()
        let calendars = eligibleCalendars()
        let predicate = eventStore.predicateForReminders(in: calendars.isEmpty ? nil : calendars)

        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        let filtered = reminders
            .filter { configuration.includeCompleted || !$0.isCompleted }
            .map { convertReminder($0) }
            .sorted { $0.lastModifiedAt < $1.lastModifiedAt }

        return filtered
    }

    public func upsert(reminders: [ReminderRecord]) async throws {
        try await ensureAuthorized()
        guard !reminders.isEmpty else { return }

        for reminder in reminders {
            let calendar = try resolveCalendar(for: reminder)
            let existing = eventStore.calendarItem(withIdentifier: reminder.externalIdentifier) as? EKReminder
            let eventReminder = existing ?? EKReminder(eventStore: eventStore)
            eventReminder.calendar = calendar
            eventReminder.title = reminder.title
            eventReminder.notes = reminder.notes
            eventReminder.isCompleted = reminder.isCompleted

            if reminder.isCompleted && eventReminder.completionDate == nil {
                eventReminder.completionDate = reminder.lastModifiedAt
            } else if !reminder.isCompleted {
                eventReminder.completionDate = nil
            }

            if let dueDate = reminder.dueDate {
                var components = Calendar.current.dateComponents(in: TimeZone.current, from: dueDate)
                if isAllDayDate(dueDate) {
                    components.hour = nil
                    components.minute = nil
                    components.second = nil
                }
                eventReminder.dueDateComponents = components
            } else {
                eventReminder.dueDateComponents = nil
            }

            do {
                try eventStore.save(eventReminder, commit: false)
            } catch {
                throw ReminderStoreError.eventKitFailure(error.localizedDescription)
            }
        }

        do {
            try eventStore.commit()
        } catch {
            throw ReminderStoreError.eventKitFailure(error.localizedDescription)
        }
    }

    public func delete(reminders: [ReminderRecord]) async throws {
        try await ensureAuthorized()
        guard !reminders.isEmpty else { return }

        for reminder in reminders {
            guard let existing = eventStore.calendarItem(withIdentifier: reminder.externalIdentifier) as? EKReminder else {
                continue
            }
            do {
                try eventStore.remove(existing, commit: false)
            } catch {
                throw ReminderStoreError.eventKitFailure(error.localizedDescription)
            }
        }

        do {
            try eventStore.commit()
        } catch {
            throw ReminderStoreError.eventKitFailure(error.localizedDescription)
        }
    }

    private func ensureAuthorized() async throws {
        let status = try await requestAccessIfNeeded()
        guard status == .authorized else {
            throw ReminderStoreError.accessDenied
        }
    }

    private func eligibleCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .reminder).filter(isCalendarEligible(_:))
    }

    private func isCalendarEligible(_ calendar: EKCalendar) -> Bool {
        if configuration.syncedListIdentifiers.isEmpty {
            return true
        }
        return configuration.syncedListIdentifiers.contains(calendar.calendarIdentifier)
    }

    private func resolveCalendar(for reminder: ReminderRecord) throws -> EKCalendar {
        if let listIdentifier = reminder.listIdentifier,
           let calendar = eventStore.calendar(withIdentifier: listIdentifier) {
            return calendar
        }
        if let defaultListIdentifier = configuration.defaultListIdentifier,
           let calendar = eventStore.calendar(withIdentifier: defaultListIdentifier) {
            return calendar
        }
        if let firstEligible = eligibleCalendars().first {
            return firstEligible
        }
        throw ReminderStoreError.listNotFound(reminder.listIdentifier ?? configuration.defaultListIdentifier ?? "<none>")
    }

    private func convertReminder(_ reminder: EKReminder) -> ReminderRecord {
        let dueDate = reminder.dueDateComponents?.date
        let lastModifiedAt = reminder.lastModifiedDate ?? configuration.dateProvider()
        return ReminderRecord(
            id: reminder.calendarItemIdentifier,
            externalIdentifier: reminder.calendarItemIdentifier,
            title: reminder.title,
            notes: reminder.notes,
            dueDate: dueDate,
            isCompleted: reminder.isCompleted,
            isDeleted: false,
            listIdentifier: reminder.calendar.calendarIdentifier,
            lastModifiedAt: lastModifiedAt,
            fingerprint: converter.fingerprint(
                title: reminder.title,
                notes: reminder.notes,
                dueDate: dueDate,
                isCompleted: reminder.isCompleted,
                listIdentifier: reminder.calendar.calendarIdentifier
            )
        )
    }

    private func isAllDayDate(_ date: Date) -> Bool {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0 && (components.second ?? 0) == 0
    }

    private static func mapAuthorizationStatus(_ status: EKAuthorizationStatus) -> ReminderAuthorizationStatus {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}
#else
public actor EventKitReminderStore: ReminderStore {
    public init(
        configuration: EventKitReminderStoreConfiguration = .init(),
        converter: any ReminderDTOConverting = DefaultReminderDTOConverter()
    ) {
        _ = configuration
        _ = converter
    }

    public func authorizationStatus() async throws -> ReminderAuthorizationStatus {
        throw ReminderStoreError.eventKitUnavailable
    }

    public func requestAccessIfNeeded() async throws -> ReminderAuthorizationStatus {
        throw ReminderStoreError.eventKitUnavailable
    }

    public func fetchReminderLists() async throws -> [ReminderListRecord] {
        throw ReminderStoreError.eventKitUnavailable
    }

    public func fetchReminders() async throws -> [ReminderRecord] {
        throw ReminderStoreError.eventKitUnavailable
    }

    public func upsert(reminders: [ReminderRecord]) async throws {
        _ = reminders
        throw ReminderStoreError.eventKitUnavailable
    }

    public func delete(reminders: [ReminderRecord]) async throws {
        _ = reminders
        throw ReminderStoreError.eventKitUnavailable
    }
}
#endif

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

    public func fetchReminderLists() async throws -> [ReminderListRecord] {
        let identifiers = Set(storage.values.compactMap(\.listIdentifier))
        return identifiers.sorted().map { ReminderListRecord(identifier: $0, title: $0) }
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
