import BridgeModels
import Foundation
import HTTPClient
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class URLSessionBackendSyncClientContractTests: XCTestCase {
    func testPullChangesDecodesBackendContractFixture() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: pullFixture.data(using: .utf8)!)
        let client = makeClient(session: session)

        let response = try await client.pullChanges(
            request: PullChangesRequest(
                bridgeID: "bridge-contract",
                cursor: "cursor-41",
                limit: 50,
                localChanges: []
            )
        )

        let lastRequest = await session.getLastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sync/apple/pull")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let requestBody = try XCTUnwrap(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        XCTAssertEqual(payload?["bridge_id"] as? String, "bridge-contract")
        XCTAssertEqual(payload?["cursor"] as? String, "cursor-41")
        XCTAssertEqual(payload?["limit"] as? Int, 50)

        XCTAssertEqual(response.accepted, 1)
        XCTAssertEqual(response.applied, 1)
        XCTAssertEqual(response.backendCursor, "cursor-42")
        XCTAssertEqual(response.nextCursor, "cursor-42")
        XCTAssertFalse(response.hasMore)
        XCTAssertEqual(response.changes.count, 1)

        guard let task = response.changes.first else {
            XCTFail("Expected first change")
            return
        }
        XCTAssertEqual(task.id, "task-backend-1")
        XCTAssertEqual(task.title, "Remote Inbox Task")
        XCTAssertEqual(task.notes, "Pulled from backend")
        XCTAssertEqual(task.listName, "Inbox")
        XCTAssertEqual(task.versionToken, "v7")
        XCTAssertEqual(task.changeID, 42)
        XCTAssertEqual(task.sourceRecordID, "reminder-ext-1")
        XCTAssertEqual(task.state, SyncEntityState.active)
    }

    func testPushChangesDecodesBackendContractFixture() async throws {
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
                        title: "Remote Inbox Task",
                        notes: "Pulled from backend",
                        isAllDayDue: false,
                        listName: "Inbox",
                        listIdentifier: "inbox",
                        externalIdentifier: "reminder-ext-1",
                        state: .active,
                        fingerprint: ReminderFingerprint(value: "fp-1"),
                        lastModifiedAt: Date(timeIntervalSince1970: 1_742_368_000),
                        backendVersionToken: "v8",
                        backendChangeID: 43
                    )
                ],
                limit: 20
            )
        )

        let lastRequest = await session.getLastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url?.path, "/api/sync/apple/push")

        let requestBody = try XCTUnwrap(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        XCTAssertEqual(payload?["bridge_id"] as? String, "bridge-contract")
        XCTAssertEqual(payload?["cursor"] as? String, "push-cursor-1")
        XCTAssertEqual(payload?["limit"] as? Int, 20)
        let tasks = try XCTUnwrap(payload?["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?["task_id"] as? String, "task-backend-1")
        XCTAssertEqual(tasks.first?["reminder_id"] as? String, "reminder-local-1")
        XCTAssertEqual(tasks.first?["title"] as? String, "Remote Inbox Task")
        XCTAssertEqual(tasks.first?["backend_version_token"] as? String, "v8")

        XCTAssertEqual(response.accepted.count, 1)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.nextCursor, "cursor-push-9")
        XCTAssertFalse(response.hasMore)

        guard let item = response.items.first else {
            XCTFail("Expected first item")
            return
        }
        XCTAssertEqual(item.taskID, "task-backend-1")
        XCTAssertEqual(item.version, 8)
        XCTAssertEqual(item.changeID, 43)
        XCTAssertEqual(item.operation, "upsert")
        XCTAssertEqual(item.task.state, SyncEntityState.completed)
        XCTAssertEqual(item.task.versionToken, "v8")
        XCTAssertEqual(item.task.sourceRecordID, "reminder-local-1")

        guard let accepted = response.accepted.first else {
            XCTFail("Expected first accepted result")
            return
        }
        XCTAssertEqual(accepted.reminderID, "reminder-local-1")
        XCTAssertEqual(accepted.task.id, "task-backend-1")
    }

    func testAckChangesSendsExpectedPayloadAndAcceptsCheckpointEnvelope() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: ackFixture.data(using: .utf8)!)
        let client = makeClient(session: session)

        try await client.ackChanges(
            request: AckRequest(
                bridgeID: "bridge-contract",
                acknowledgements: [
                    AckItem(taskID: "task-backend-1", version: 8, changeID: 43, status: "applied")
                ]
            )
        )

        let lastRequest = await session.getLastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url?.path, "/api/sync/apple/ack")
        let requestBody = try XCTUnwrap(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        XCTAssertEqual(payload?["bridge_id"] as? String, "bridge-contract")
        let acks = payload?["acks"] as? [[String: Any]]
        XCTAssertEqual(acks?.count, 1)
        XCTAssertEqual(acks?.first?["task_id"] as? String, "task-backend-1")
        XCTAssertEqual(acks?.first?["change_id"] as? Int, 43)
        XCTAssertEqual(acks?.first?["status"] as? String, "applied")
    }

    func testUnexpectedStatusCodeIncludesBodyForDiagnostics() async throws {
        let session = StubURLSession(response: .http(statusCode: 409), data: Data("{\"detail\":\"conflict\"}".utf8))
        let client = makeClient(session: session)

        do {
            _ = try await client.pullChanges(
                request: PullChangesRequest(bridgeID: "bridge-contract", cursor: nil, limit: 10, localChanges: [])
            )
            XCTFail("Expected unexpectedStatusCode error")
        } catch let error as BackendClientError {
            guard case let .unexpectedStatusCode(code, body) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(code, 409)
            XCTAssertTrue(body.contains("conflict"))
        }
    }

    func testDecodingFailureSurfacesContractMismatch() async throws {
        let session = StubURLSession(response: .http(statusCode: 200), data: Data("{\"accepted\":1,\"applied\":1,\"results\":[]}".utf8))
        let client = makeClient(session: session)

        do {
            _ = try await client.pullChanges(
                request: PullChangesRequest(bridgeID: "bridge-contract", cursor: nil, limit: 10, localChanges: [])
            )
            XCTFail("Expected decodingFailed error")
        } catch let error as BackendClientError {
            guard case let .decodingFailed(message) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertTrue(message.contains("checkpoint"))
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
    private var lastRequest: URLRequest?

    init(response: HTTPURLResponse, data: Data) {
        self.response = response
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return (data, response)
    }

    func getLastRequest() -> URLRequest? {
        lastRequest
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
  "accepted": [
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
