import SwiftUI

@main
struct Band9DiagnosticsApp: App {
    @StateObject private var bluetooth = BluetoothModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: bluetooth)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { bluetooth.suspend() }
                }
        }
    }
}
