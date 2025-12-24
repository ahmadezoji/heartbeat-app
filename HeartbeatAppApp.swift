import SwiftUI

@main
struct HeartbeatAppApp: App {
    @StateObject private var audioManager = AudioEngineManager()
    @StateObject private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(audioManager)
                .environmentObject(locationManager)
        }
    }
}
