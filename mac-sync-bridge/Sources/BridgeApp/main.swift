import BridgeRuntime
import Foundation

@main
struct BridgeAppMain {
    static func main() {
        let configPath = NSString(string: BridgeRuntimeConfiguration.defaultConfigPath).expandingTildeInPath
        print("BridgeApp scaffold. Next step: wrap LaunchAgent/menu bar host around BridgeRuntime. Default config path: \(configPath)")
    }
}
