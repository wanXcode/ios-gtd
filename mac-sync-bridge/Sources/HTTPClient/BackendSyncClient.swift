import BridgeModels
import Foundation

public protocol BackendSyncClient: Sendable {
    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse
    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse
    func ackChanges(request: AckRequest) async throws
}

public struct BackendClientConfiguration: Sendable {
    public var baseURL: URL
    public var apiToken: String?
    public var timeout: TimeInterval

    public init(baseURL: URL, apiToken: String? = nil, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.timeout = timeout
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
