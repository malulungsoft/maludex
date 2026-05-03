import SwiftUI

@main
struct MaludexApp: App {
    @StateObject private var bridge = BridgeClient()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--demo-video") {
                DemoVideoView()
            } else {
                ContentView()
                    .environmentObject(bridge)
            }
        }
    }
}
