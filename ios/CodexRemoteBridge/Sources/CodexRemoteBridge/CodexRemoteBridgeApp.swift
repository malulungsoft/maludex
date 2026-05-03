import SwiftUI

@main
struct MaludexApp: App {
    @StateObject private var bridge = BridgeClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
        }
    }
}
