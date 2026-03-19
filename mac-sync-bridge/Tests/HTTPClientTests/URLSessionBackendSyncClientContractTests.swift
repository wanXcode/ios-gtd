import BridgeModels
import Foundation
import HTTPClient
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct URLSessionBackendSyncClientContractTests {
    @Test
    func pullChangesDecodesBackendContractFixture() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: pullFixture.data(using: .utf8)!)
        let client = makeClient(session: session)

        let response = try await client.pullChanges(
            request: PullChangesRequest(
                bridgeID: "bridge-contract",
                cursor: "cursor-41",
                localChanges: [],
                limit: 50
            )
        )

        let request = try #require(await session.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/sync/apple/pull")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let requestBody = try #require(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        #expect(payload?["bridge_id"] as? String == "bridge-contract")
        #expect(payload?["cursor"] as? String == "cursor-41")
        #expect(payload?["limit"] as? Int == 50)

        #expect(response.accepted == 1)
        #expect(response.applied == 1)
        #expect(response.backendCursor == "cursor-42")
        #expect(response.nextCursor == "cursor-42")
        #expect(!response.hasMore)
        #expect(response.changes.count == 1)

        let task = try #require(response.changes.first)
        #expect(task.id == "task-backend-1")
        #expect(task.title == "Remote Inbox Task")
        #expect(task.notes == "Pulled from backend")
        #expect(task.listName == "Inbox")
        #expect(task.versionToken == "v7")
        #expect(task.changeID == 42)
        #expect(task.sourceRecordID == "reminder-ext-1")
        #expect(task.state == .active)
    }

    @Test
    func pushChangesDecodesBackendContractFixture() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: pushFixture.data(using: .utf8)!)
        let client = makeClient(session: session)

        let response = try await client.pushChanges(
            request: PushChangesRequest(
                bridgeID: "bridge-contract",
                cursor: "push-cursor-1",
                tasks: [
                    PushTaskMutation(
                        taskID: "task-backend-1",
                        reminderID: "reminder-local-1",
                        title: "Local title",
                        notes: "Changed locally",
                        dueDate: Date(timeIntervalSince1970: 1_710_000_000),
                        state: .completed,
                        listIdentifier: "list-inbox",
                        fingerprint: ReminderFingerprint(value: "fp-local-1"),
                        lastModifiedAt: Date(timeIntervalSince1970: 1_710_000_100),
                        backendVersionToken: "v7"
                    )
                ],
                limit: 20
            )
        )

        let request = try #require(await session.lastRequest)
        #expect(request.url?.path == "/api/sync/apple/push")

        let requestBody = try #require(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        #expect(payload?["bridge_id"] as? String == "bridge-contract")
        #expect(payload?["cursor"] as? String == "push-cursor-1")
        #expect(payload?["limit"] as? Int == 20)

        #expect(response.accepted.count == 1)
        #expect(response.items.count == 1)
        #expect(response.nextCursor == "cursor-push-9")
        #expect(!response.hasMore)

        let item = try #require(response.items.first)
        #expect(item.taskID == "task-backend-1")
        #expect(item.version == 8)
        #expect(item.changeID == 43)
        #expect(item.operation == "upsert")
        #expect(item.task.state == .completed)
        #expect(item.task.versionToken == "v8")
        #expect(item.task.sourceRecordID == "reminder-local-1")

        let accepted = try #require(response.accepted.first)
        #expect(accepted.reminderID == "reminder-local-1")
        #expect(accepted.task.id == "task-backend-1")
    }

    @Test
    func ackChangesSendsExpectedPayloadAndAcceptsCheckpointEnvelope() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: ackFixture.data(using: .utf8)!)
        let client = makeClient(session: session)

        try await client.ackChanges(
            request: AckRequest(
                bridgeID: "bridge-contract",
                acknowledgements: [
                    AckItem(taskID: "task-backend-1", version: 8, status: .applied, changeID: 43)
                ]
            )
        )

        let request = try #require(await session.lastRequest)
        #expect(request.url?.path == "/api/sync/apple/ack")
        let requestBody = try #require(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        #expect(payload?["bridge_id"] as? String == "bridge-contract")
        let acks = payload?["acks"] as? [[String: Any]]
        #expect(acks?.count == 1)
        #expect(acks?.first?["task_id"] as? String == "task-backend-1")
        #expect(acks?.first?["change_id"] as? Int == 43)
        #expect(acks?.first?["status"] as? String == "applied")
    }

    @Test
    func unexpectedStatusCodeIncludesBodyForDiagnostics() async throws {
        let session = StubURLSession(response: .http(statusCode: 409), data: Data("{\"detail\":\"conflict\"}".utf8))
        let client = makeClient(session: session)

        await #expect(throws: BackendClientError.self) {
            try await client.pullChanges(
                request: PullChangesRequest(bridgeID: "bridge-contract", cursor: nil, localChanges: [], limit: 10)
            )
        } matching: { error in
            guard case let .unexpectedStatusCode(code, body) = error else {
                return false
            }
            return code == 409 && body.contains("conflict")
        }
    }

    @Test
    func decodingFailureSurfacesContractMismatch() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: Data("{\"accepted\":1,\"applied\":1,\"results\":[]}".utf8))
        let client = makeClient(session: session)

        await #expect(throws: BackendClientError.self) {
            try await client.pullChanges(
                request: PullChangesRequest(bridgeID: "bridge-contract", cursor: nil, localChanges: [], limit: 10)
            )
        } matching: { error in
            guard case let .decodingFailed(message) = error else {
                return false
            }
            return message.contains("checkpoint")
        }
    }

    private func makeClient(session: some URLSessioning) -> URLSessionBackendSyncClient {
        URLSessionBackendSyncClient(
            configuration: BackendClientConfiguration(
                baseURL: URL(string: "https://example.test")!,
                apiToken: "test-token"
            ),
            session: session
        )
    }
}

private actor StubURLSession: URLSessioning {
    let response: HTTPURLResponse
    let data: Data
    private(set) var lastRequest: URLRequest?

    init(response: HTTPURLResponse, data: Data) {
        self.response = response
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return (data, response)
    }
}

private extension HTTPURLResponse {
    static func http(statusCode: Int, url: URL = URL(string: "https://example.test")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
}

private let pullFixture = #"""
{
  "accepted": 1,
  "applied": 1,
  "results": [
    {
      "task_id": "task-backend-1",
      "version": 7,
      "result": "updated",
      "task": {
        "title": "Remote Inbox Task",
        "note": "Pulled from backend",
        "due_at": "2026-03-19T09:00:00Z",
        "remind_at": "2026-03-19T08:30:00Z",
        "is_all_day_due": false,
        "priority": 3,
        "list_name": "Inbox",
        "source_ref": "reminder-ext-1",
        "updated_at": "2026-03-19T09:01:00Z",
        "version": 7,
        "change_id": 42,
        "status": "active",
        "bucket": "inbox"
      }
    }
  ],
  "checkpoint": {
    "backend_cursor": "cursor-42",
    "last_push_cursor": "cursor-push-8",
    "last_acked_change_id": 41
  }
}
"""#

private let pushFixture = #"""
{
  "mode": "delta",
  "items": [
    {
      "task_id": "task-backend-1",
      "version": 8,
      "change_id": 43,
      "operation": "upsert",
      "task": {
        "title": "Local title",
        "note": "Changed locally",
        "due_at": "2026-03-19T10:00:00Z",
        "remind_at": "2026-03-19T09:45:00Z",
        "is_all_day_due": false,
        "priority": 2,
        "list_name": "Inbox",
        "source_ref": "reminder-local-1",
        "updated_at": "2026-03-19T10:01:00Z",
        "version": 8,
        "change_id": 43,
        "status": "completed",
        "bucket": "done"
      }
    }
  ],
  "checkpoint": {
    "backend_cursor": "cursor-43",
    "last_push_cursor": "cursor-push-9",
    "last_acked_change_id": 42
  }
}
"""#

private let ackFixture = #"""
{
  "success": 1,
  "failed": 0,
  "checkpoint": {
    "backend_cursor": "cursor-43",
    "last_push_cursor": "cursor-push-9",
    "last_acked_change_id": 43
  }
}
"""#
