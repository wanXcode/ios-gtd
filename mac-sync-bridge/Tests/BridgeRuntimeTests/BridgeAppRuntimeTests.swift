import BridgeCore
import BridgeModels
import BridgeRuntime
import EventKitAdapter
import Foundation
import HTTPClient
import Persistence
import Testing

struct BridgeAppRuntimeTests {
    @Test
    func bridgeAppLoopRunsConfiguredIterationsAndSleepsBetweenRuns() async throws {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let clock = IncrementingDateProvider(start: now)
        let coordinator = SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: InMemoryReminderStore(reminders: []),
                backendClient: InMemoryBackendSyncClient(tasks: []),
                bridgeStore: InMemoryBridgeStateStore(
                    configuration: BridgeConfiguration(backendBaseURL: URL(string: "https://example.com")!)
                ),
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(),
                dateProvider: clock,
                bridgeID: "runtime-test-bridge"
            )
        )
        let runtime = BridgeRuntime(
            configuration: BridgeRuntimeConfiguration(
                bridgeID: "runtime-test-bridge",
                backendBaseURL: URL(string: "https://example.com")!,
                syncIntervalSeconds: 42
            ),
            coordinator: coordinator,
            bridgeStore: InMemoryBridgeStateStore(
                configuration: BridgeConfiguration(backendBaseURL: URL(string: "https://example.com")!)
            ),
            reminderStore: InMemoryReminderStore(reminders: [])
        )
        let ticker = RecordingTicker()
        let logger = RecordingLogger()
        let appRuntime = BridgeAppRuntime(
            runtime: runtime,
            ticker: ticker,
            logger: logger,
            dateProvider: clock,
            launchConfiguration: BridgeAppLaunchConfiguration(runInitialSyncOnLaunch: true, maxSyncIterations: 2)
        )

        let summary = try await appRuntime.run()
        let sleepIntervals = await ticker.intervals
        let messages = await logger.messages

        #expect(summary.iterationResults.count == 2)
        #expect(sleepIntervals == [42])
        #expect(messages.contains { $0.contains("iteration=1 sync started") })
        #expect(messages.contains { $0.contains("iteration=2 sync finished") })
    }

    @Test
    func bridgeAppLoopContinuesAfterSyncFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let clock = IncrementingDateProvider(start: now)
        let runtime = BridgeRuntime(
            configuration: BridgeRuntimeConfiguration(
                bridgeID: "runtime-failure-bridge",
                backendBaseURL: URL(string: "https://example.com")!,
                syncIntervalSeconds: 15
            ),
            coordinator: FailingSyncCoordinatorFactory.make(dateProvider: clock),
            bridgeStore: InMemoryBridgeStateStore(
                configuration: BridgeConfiguration(backendBaseURL: URL(string: "https://example.com")!)
            ),
            reminderStore: InMemoryReminderStore(reminders: [])
        )
        let ticker = RecordingTicker()
        let logger = RecordingLogger()
        let appRuntime = BridgeAppRuntime(
            runtime: runtime,
            ticker: ticker,
            logger: logger,
            dateProvider: clock,
            launchConfiguration: BridgeAppLaunchConfiguration(runInitialSyncOnLaunch: true, maxSyncIterations: 2)
        )

        let summary = try await appRuntime.run()
        let sleepIntervals = await ticker.intervals
        let messages = await logger.messages

        #expect(summary.iterationResults.count == 2)
        #expect(sleepIntervals == [15])
        #expect(summary.iterationResults.allSatisfy {
            if case .failed = $0.outcome { return true }
            return false
        })
        #expect(messages.contains { $0.contains("sync failed") })
    }
}

private actor RecordingTicker: BridgeRuntimeTicking {
    private(set) var intervals: [TimeInterval] = []

    func sleep(for interval: TimeInterval) async throws {
        intervals.append(interval)
    }
}

private actor RecordingLogger: BridgeRuntimeLogging {
    private(set) var messages: [String] = []

    func log(_ message: String) async {
        messages.append(message)
    }
}

private actor IncrementingDateProvider: DateProviding {
    private var current: Date

    init(start: Date) {
        self.current = start
    }

    func now() -> Date {
        defer { current = current.addingTimeInterval(1) }
        return current
    }
}

private enum TestFailure: Error {
    case expected
}

private enum FailingSyncCoordinatorFactory {
    static func make(dateProvider: some DateProviding) -> SyncCoordinator {
        SyncCoordinator(
            dependencies: SyncCoordinatorDependencies(
                reminderStore: InMemoryReminderStore(reminders: []),
                backendClient: ThrowingBackendSyncClient(),
                bridgeStore: InMemoryBridgeStateStore(
                    configuration: BridgeConfiguration(backendBaseURL: URL(string: "https://example.com")!)
                ),
                conflictResolver: LastWriteWinsConflictResolver(),
                retryScheduler: ExponentialBackoffRetryScheduler(),
                dateProvider: dateProvider,
                bridgeID: "runtime-failure-bridge"
            )
        )
    }
}

private actor ThrowingBackendSyncClient: BackendSyncClient {
    func pullChanges(request: PullChangesRequest) async throws -> PullChangesResponse {
        _ = request
        throw TestFailure.expected
    }

    func pushChanges(request: PushChangesRequest) async throws -> PushChangesResponse {
        _ = request
        throw TestFailure.expected
    }

    func ackChanges(request: AckRequest) async throws {
        _ = request
        throw TestFailure.expected
    }
}
