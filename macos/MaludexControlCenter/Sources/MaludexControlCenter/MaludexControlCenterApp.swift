import SwiftUI

@main
struct MaludexControlCenterApp: App {
    var body: some Scene {
        WindowGroup("maludex Control Center") {
            ControlCenterView()
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}
