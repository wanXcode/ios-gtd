import BridgeCore
import BridgeModels
import EventKitAdapter
import Foundation
import Persistence

public protocol BridgeRuntimeTicking: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

public struct TaskSleepTicker: BridgeRuntimeTicking {
    public init() {}

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        let duration = UInt64(interval * 1_000_000_000)
        try await Task.sleep(nanoseconds: duration)
    }
}

public protocol BridgeRuntimeLogging: Sendable {
    func log(_ message: String) async
}

public actor StdoutBridgeRuntimeLogger: BridgeRuntimeLogging {
    private let iso8601Formatter: ISO8601DateFormatter

    public init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = formatter
    }

    public func log(_ message: String) {
        let timestamp = iso8601Formatter.string(from: Date())
        print("[\(timestamp)] \(message)")
    }
}

public struct BridgeAppLaunchConfiguration: Sendable {
    public var runInitialSyncOnLaunch: Bool
    public var maxSyncIterations: Int?

    public init(
        runInitialSyncOnLaunch: Bool = true,
        maxSyncIterations: Int? = nil
    ) {
        self.runInitialSyncOnLaunch = runInitialSyncOnLaunch
        self.maxSyncIterations = maxSyncIterations
    }
}

public struct BridgeLoopIterationResult: Sendable {
    public let iteration: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let outcome: BridgeLoopIterationOutcome

    public init(iteration: Int, startedAt: Date, finishedAt: Date, outcome: BridgeLoopIterationOutcome) {
        self.iteration = iteration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
    }
}

public enum BridgeLoopIterationOutcome: Sendable {
    case synced(SyncRunReport)
    case failed(String)
}

public struct BridgeAppLoopSummary: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let iterationResults: [BridgeLoopIterationResult]

    public init(startedAt: Date, finishedAt: Date, iterationResults: [BridgeLoopIterationResult]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.iterationResults = iterationResults
    }
}

public actor BridgeAppRuntime {
    private let runtime: BridgeRuntime
    private let ticker: any BridgeRuntimeTicking
    private let logger: any BridgeRuntimeLogging
    private let dateProvider: any DateProviding
    private let launchConfiguration: BridgeAppLaunchConfiguration

    public init(
        runtime: BridgeRuntime,
        ticker: any BridgeRuntimeTicking = TaskSleepTicker(),
        logger: any BridgeRuntimeLogging = StdoutBridgeRuntimeLogger(),
        dateProvider: any DateProviding = SystemDateProvider(),
        launchConfiguration: BridgeAppLaunchConfiguration = .init()
    ) {
        self.runtime = runtime
        self.ticker = ticker
        self.logger = logger
        self.dateProvider = dateProvider
        self.launchConfiguration = launchConfiguration
    }

    public func run() async throws -> BridgeAppLoopSummary {
        let startedAt = dateProvider.now()
        let maxIterations = launchConfiguration.maxSyncIterations
        var iterationResults: [BridgeLoopIterationResult] = []
        var iteration = 0

        while !Task.isCancelled {
            iteration += 1
            if iteration > 1 || launchConfiguration.runInitialSyncOnLaunch {
                let result = await performIteration(iteration: iteration)
                iterationResults.append(result)
            }

            if let maxIterations, iteration >= maxIterations {
                break
            }

            await logger.log("bridge-app sleeping for \(Int(runtime.configuration.syncIntervalSeconds))s before next sync")
            do {
                try await ticker.sleep(for: runtime.configuration.syncIntervalSeconds)
            } catch is CancellationError {
                await logger.log("bridge-app cancelled during sleep")
                break
            }
        }

        let finishedAt = dateProvider.now()
        return BridgeAppLoopSummary(startedAt: startedAt, finishedAt: finishedAt, iterationResults: iterationResults)
    }

    private func performIteration(iteration: Int) async -> BridgeLoopIterationResult {
        let startedAt = dateProvider.now()
        do {
            await logger.log("bridge-app iteration=\(iteration) sync started bridge_id=\(runtime.configuration.bridgeID)")
            let report = try await runtime.coordinator.runSync(direction: .bidirectional)
            await logger.log(
                "bridge-app iteration=\(iteration) sync finished pulled=\(report.pulledCount) pushed=\(report.pushedCount) acked=\(report.ackedCount) conflicts=\(report.conflictCount) retries=\(report.queuedRetryCount) pending_consumed=\(report.consumedPendingCount)"
            )
            return BridgeLoopIterationResult(
                iteration: iteration,
                startedAt: startedAt,
                finishedAt: dateProvider.now(),
                outcome: .synced(report)
            )
        } catch is CancellationError {
            await logger.log("bridge-app iteration=\(iteration) cancelled")
            return BridgeLoopIterationResult(
                iteration: iteration,
                startedAt: startedAt,
                finishedAt: dateProvider.now(),
                outcome: .failed("cancelled")
            )
        } catch {
            await logger.log("bridge-app iteration=\(iteration) sync failed error=\(error.localizedDescription)")
            return BridgeLoopIterationResult(
                iteration: iteration,
                startedAt: startedAt,
                finishedAt: dateProvider.now(),
                outcome: .failed(String(describing: error))
            )
        }
    }
}
