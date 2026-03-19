import BridgeModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol BackendSyncClient: Sendable {
    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse
    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse
    func ackChanges(request: AckRequest) async throws
}

public struct BackendClientConfiguration: Sendable {
    public var baseURL: URL
    public var apiToken: String?
    public var timeout: TimeInterval
    public var additionalHeaders: [String: String]
    public var jsonEncoder: JSONEncoder
    public var jsonDecoder: JSONDecoder

    public init(
        baseURL: URL,
        apiToken: String? = nil,
        timeout: TimeInterval = 30,
        additionalHeaders: [String: String] = [:],
        jsonEncoder: JSONEncoder = BackendClientConfiguration.defaultJSONEncoder(),
        jsonDecoder: JSONDecoder = BackendClientConfiguration.defaultJSONDecoder()
    ) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.timeout = timeout
        self.additionalHeaders = additionalHeaders
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder
    }

    public static func defaultJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func defaultJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try multiple ISO8601 variants to be tolerant of backend formats
            let formatters: [ISO8601DateFormatter] = [
                { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }(),
                { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]; return f }(),
                { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withFullTime]; return f }(),
            ]
            
            for formatter in formatters {
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }
            
            // Fallback: try DateFormatter for formats without Z
            let fallbackFormatters: [DateFormatter] = [
                { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.timeZone = TimeZone(secondsFromGMT: 0); return f }(),
                { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"; f.timeZone = TimeZone(secondsFromGMT: 0); return f }(),
                { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"; f.timeZone = TimeZone(secondsFromGMT: 0); return f }(),
            ]
            
            for formatter in fallbackFormatters {
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string: \(dateString)")
        }
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

public struct BackendEndpointSet: Sendable {
    public var pullPath: String
    public var pushPath: String
    public var ackPath: String

    public init(
        pullPath: String = "/api/sync/apple/pull",
        pushPath: String = "/api/sync/apple/push",
        ackPath: String = "/api/sync/apple/ack"
    ) {
        self.pullPath = pullPath
        self.pushPath = pushPath
        self.ackPath = ackPath
    }
}

public protocol URLSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessioning {}

public enum BackendClientError: Error, Sendable, LocalizedError {
    case invalidResponse
    case unexpectedStatusCode(Int, body: String)
    case encodingFailed(String)
    case invalidURL(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response"
        case let .unexpectedStatusCode(code, body):
            return "Unexpected status code \(code): \(body)"
        case let .encodingFailed(reason):
            return "Failed to encode request body: \(reason)"
        case let .invalidURL(path):
            return "Invalid URL for path: \(path)"
        case let .decodingFailed(reason):
            return "Failed to decode response body: \(reason)"
        }
    }
}

public final class URLSessionBackendSyncClient: BackendSyncClient, @unchecked Sendable {
    private let configuration: BackendClientConfiguration
    private let endpoints: BackendEndpointSet
    private let session: any URLSessioning

    public init(
        configuration: BackendClientConfiguration,
        endpoints: BackendEndpointSet = .init(),
        session: any URLSessioning = URLSession.shared
    ) {
        self.configuration = configuration
        self.endpoints = endpoints
        self.session = session
    }

    public func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        let response: APIPullResponse = try await sendJSON(
            method: "POST",
            path: endpoints.pullPath,
            body: request,
            responseType: APIPullResponse.self
        )
        return PullChangesResponse(
            accepted: response.accepted,
            applied: response.applied,
            changes: response.results.map(\.backendTaskRecord),
            nextCursor: response.checkpoint.backendCursor ?? request.cursor,
            backendCursor: response.checkpoint.backendCursor,
            hasMore: false
        )
    }

    public func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        let response: APIPushResponse = try await sendJSON(
            method: "POST",
            path: endpoints.pushPath,
            body: request,
            responseType: APIPushResponse.self
        )
        let acceptedItems = (response.accepted ?? response.items).map(\.remoteEnvelope)
        let items = response.items.map(\.remoteEnvelope)
        let accepted: [PushTaskResult] = matchAcceptedResults(requestTasks: request.tasks, acceptedItems: acceptedItems)
        return PushChangesResponse(
            accepted: accepted,
            rejectedReminderIDs: response.rejectedReminderIDs,
            items: items,
            nextCursor: response.checkpoint.lastPushCursor,
            hasMore: false
        )
    }

    public func ackChanges(request: AckRequest) async throws {
        _ = try await sendJSON(
            method: "POST",
            path: endpoints.ackPath,
            body: request,
            responseType: APIAckResponse.self
        )
    }

    private func matchAcceptedResults(
        requestTasks: [PushTaskMutation],
        acceptedItems: [RemoteTaskEnvelope]
    ) -> [PushTaskResult] {
        matchAcceptedPushResults(requestTasks: requestTasks, acceptedItems: acceptedItems)
    }

    private func sendJSON<RequestBody: Encodable, ResponseBody: Decodable>(
        method: String,
        path: String,
        body: RequestBody,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = try buildRequest(method: method, path: path)
        do {
            request.httpBody = try configuration.jsonEncoder.encode(body)
        } catch {
            throw BackendClientError.encodingFailed(String(describing: error))
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        return try decodeResponse(data: data, response: response, responseType: responseType)
    }

    private func buildRequest(method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw BackendClientError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        if let token = configuration.apiToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func decodeResponse<ResponseBody: Decodable>(
        data: Data,
        response: URLResponse,
        responseType: ResponseBody.Type
    ) throws -> ResponseBody {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8-body>"
            throw BackendClientError.unexpectedStatusCode(httpResponse.statusCode, body: body)
        }

        do {
            return try configuration.jsonDecoder.decode(ResponseBody.self, from: data)
        } catch {
            throw BackendClientError.decodingFailed(String(describing: error))
        }
    }
}

public actor InMemoryBackendSyncClient: BackendSyncClient {
    private var tasks: [String: BackendTaskRecord]
    private var cursorSequence: Int

    public init(tasks: [BackendTaskRecord] = []) {
        self.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        self.cursorSequence = tasks.count
    }

    public func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        let changes = tasks.values.sorted { $0.updatedAt < $1.updatedAt }
        return PullChangesResponse(
            accepted: request.localChanges.count,
            applied: request.localChanges.count,
            changes: Array(changes.prefix(request.limit)),
            nextCursor: "cursor-\(cursorSequence)",
            backendCursor: request.localChanges.last?.appleModifiedAt.map(Self.cursorString) ?? request.cursor,
            hasMore: changes.count > request.limit
        )
    }

    public func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        let items = request.tasks.compactMap { item -> RemoteTaskEnvelope? in
            guard let taskID = item.taskID, let task = tasks[taskID] else { return nil }
            let version = item.backendVersionToken.flatMap(Self.extractVersionNumber) ?? 0
            let changeID = cursorSequence + 1
            cursorSequence = changeID
            return RemoteTaskEnvelope(taskID: taskID, version: version, changeID: changeID, operation: task.state == .deleted ? "delete" : "upsert", task: task)
        }
        let accepted: [PushTaskResult] = matchAcceptedPushResults(requestTasks: request.tasks, acceptedItems: items)
        return PushChangesResponse(
            accepted: accepted,
            items: items,
            nextCursor: items.last?.changeID.map(String.init),
            hasMore: false
        )
    }

    public func ackChanges(request: AckRequest) async throws {
        _ = request
    }

    private static func cursorString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func extractVersionNumber(_ versionToken: String) -> Int? {
        let digits = versionToken.filter(\.isNumber)
        return Int(digits)
    }
}

private struct APIPullResponse: Decodable {
    let accepted: Int
    let applied: Int
    let results: [APIPullResult]
    let checkpoint: APICheckpoint
}

private struct APIPullResult: Decodable {
    let taskId: String
    let version: Int?
    let result: String?
    let reason: String?
    let task: APIEmbeddedTask?

    var backendTaskRecord: BackendTaskRecord {
        if let task {
            return task.backendTaskRecord(taskID: taskId, fallbackVersion: version)
        }
        return BackendTaskRecord(
            id: taskId,
            title: result ?? "remote-task",
            state: .active,
            updatedAt: Date(),
            versionToken: version.map { "v\($0)" } ?? "v0"
        )
    }
}

private struct APIPushResponse: Decodable {
    let mode: String
    let accepted: [APIPushItem]?
    let items: [APIPushItem]
    let checkpoint: APICheckpoint

    var rejectedReminderIDs: [String] { [] }
}

private struct APIPushItem: Decodable {
    let taskId: String
    let version: Int
    let changeId: Int?
    let operation: String
    let task: APIEmbeddedTask

    var remoteEnvelope: RemoteTaskEnvelope {
        RemoteTaskEnvelope(
            taskID: taskId,
            version: version,
            changeID: changeId,
            operation: operation,
            task: task.backendTaskRecord(taskID: taskId, fallbackVersion: version, fallbackChangeID: changeId)
        )
    }
}

private func matchAcceptedPushResults(
    requestTasks: [PushTaskMutation],
    acceptedItems: [RemoteTaskEnvelope]
) -> [PushTaskResult] {
    var unmatchedByTaskID = Dictionary(grouping: requestTasks.enumerated(), by: { $0.element.taskID ?? "" })
    var unmatchedByExternalIdentifier = Dictionary(grouping: requestTasks.enumerated(), by: { $0.element.externalIdentifier ?? "" })
    var unmatchedByReminderID = Dictionary(grouping: requestTasks.enumerated(), by: { $0.element.reminderID })
    var consumedIndexes = Set<Int>()

    func consumeMatch(_ key: String, from buckets: inout [String: [(offset: Int, element: PushTaskMutation)]]) -> PushTaskMutation? {
        guard !key.isEmpty, var matches = buckets[key], let matched = matches.first else {
            return nil
        }
        matches.removeFirst()
        if matches.isEmpty {
            buckets.removeValue(forKey: key)
        } else {
            buckets[key] = matches
        }
        consumedIndexes.insert(matched.offset)
        return matched.element
    }

    func consumeMatch(for item: RemoteTaskEnvelope) -> PushTaskMutation? {
        if let match = consumeMatch(item.taskID, from: &unmatchedByTaskID) {
            return match
        }
        if let sourceRef = item.task.sourceRecordID {
            if let match = consumeMatch(sourceRef, from: &unmatchedByExternalIdentifier) {
                return match
            }
            if let match = consumeMatch(sourceRef, from: &unmatchedByReminderID) {
                return match
            }
        }
        return nil
    }

    let matched = acceptedItems.compactMap { item -> PushTaskResult? in
        guard let mutation = consumeMatch(for: item) else {
            return nil
        }
        return PushTaskResult(reminderID: mutation.reminderID, task: item.task)
    }

    return matched + requestTasks.enumerated().compactMap { index, mutation in
        guard !consumedIndexes.contains(index) else { return nil }
        guard let acceptedItem = acceptedItems.first(where: { $0.taskID == mutation.taskID }) else { return nil }
        consumedIndexes.insert(index)
        return PushTaskResult(reminderID: mutation.reminderID, task: acceptedItem.task)
    }
}

private struct APIAckResponse: Decodable {
    let success: Int
    let failed: Int?
    let checkpoint: APICheckpoint?
}

private struct APICheckpoint: Decodable {
    let backendCursor: String?
    let lastPushCursor: String?
    let lastAckedChangeId: Int?
}

private struct APIEmbeddedTask: Decodable {
    let title: String
    let note: String?
    let dueAt: Date?
    let remindAt: Date?
    let isAllDayDue: Bool?
    let priority: Int?
    let listName: String?
    let sourceRef: String?
    let updatedAt: Date?
    let version: Int?
    let changeId: Int?
    let deletedAt: Date?
    let status: String?
    let bucket: String?

    func backendTaskRecord(taskID: String, fallbackVersion: Int?, fallbackChangeID: Int? = nil) -> BackendTaskRecord {
        BackendTaskRecord(
            id: taskID,
            title: title,
            notes: note,
            dueDate: dueAt,
            remindAt: remindAt,
            isAllDayDue: isAllDayDue ?? false,
            priority: priority,
            listName: listName,
            state: mapState(status: status, bucket: bucket, deletedAt: deletedAt),
            updatedAt: updatedAt ?? Date(),
            deletedAt: deletedAt,
            versionToken: "v\(version ?? fallbackVersion ?? 0)",
            changeID: changeId ?? fallbackChangeID,
            sourceRecordID: sourceRef,
            sourceListID: listName,
            sourceCalendarID: listName
        )
    }

    private func mapState(status: String?, bucket: String?, deletedAt: Date?) -> SyncEntityState {
        if deletedAt != nil { return .deleted }
        if status == "completed" || bucket == "done" { return .completed }
        return .active
    }
}
