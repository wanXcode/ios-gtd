import BridgeRuntime
import Foundation

@main
struct BridgeAppMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let loader = BridgeRuntimeConfigurationLoader()
            let configuration = try loader.load(arguments: arguments)
            let runtime = try await loader.makeRuntime(configuration: configuration)
            let appRuntime = BridgeAppRuntime(
                runtime: runtime,
                launchConfiguration: BridgeAppLaunchConfiguration(
                    runInitialSyncOnLaunch: true,
                    maxSyncIterations: maxIterations(from: arguments)
                )
            )
            let summary = try await appRuntime.run()
            print("bridge-app stopped iterations=\(summary.iterationResults.count) bridge_id=\(configuration.bridgeID)")
        } catch {
            fputs("bridge-app failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func maxIterations(from arguments: [String]) -> Int? {
        if let index = arguments.firstIndex(of: "--once") {
            _ = index
            return 1
        }

        if let rawValue = optionValue(named: "max-iterations", in: arguments), let parsed = Int(rawValue), parsed > 0 {
            return parsed
        }

        return nil
    }

    private static func optionValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = "--\(name)="
        if let inline = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: "--\(name)"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
