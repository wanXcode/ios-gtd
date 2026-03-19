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
        jsonEncoder: JSONEncoder = BackendClientConfiguration.makeDefaultEncoder(),
        jsonDecoder: JSONDecoder = BackendClientConfiguration.makeDefaultDecoder()
    ) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.timeout = timeout
        self.additionalHeaders = additionalHeaders
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder
    }

    private static func makeDefaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDefaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
        try await sendJSON(
            method: "POST",
            path: endpoints.pullPath,
            body: request,
            responseType: PullChangesResponse.self
        )
    }

    public func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        try await sendJSON(
            method: "POST",
            path: endpoints.pushPath,
            body: request,
            responseType: PushChangesResponse.self
        )
    }

    public func ackChanges(request: AckRequest) async throws {
        _ = try await sendJSON(
            method: "POST",
            path: endpoints.ackPath,
            body: request,
            responseType: EmptyResponse.self
        )
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

        if ResponseBody.self == EmptyResponse.self {
            return EmptyResponse() as! ResponseBody
        }

        return try configuration.jsonDecoder.decode(ResponseBody.self, from: data)
    }
}

private struct EmptyResponse: Codable {}

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
            changes: Array(changes.prefix(request.limit)),
            nextCursor: "cursor-\(cursorSequence)",
            hasMore: changes.count > request.limit
        )
    }

    public func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        var accepted: [PushTaskResult] = []
        for change in request.changes {
            let taskID = change.taskID ?? UUID().uuidString
            let task = BackendTaskRecord(
                id: taskID,
                title: change.title,
                notes: change.notes,
                dueDate: change.dueDate,
                state: change.state,
                updatedAt: change.lastModifiedAt,
                deletedAt: change.state == .deleted ? change.lastModifiedAt : nil,
                versionToken: "v\(cursorSequence + 1)"
            )
            tasks[taskID] = task
            accepted.append(.init(reminderID: change.reminderID, task: task))
            cursorSequence += 1
        }
        return PushChangesResponse(accepted: accepted)
    }

    public func ackChanges(request: AckRequest) async throws {
        _ = request
    }
}
