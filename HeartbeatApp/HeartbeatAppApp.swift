import SwiftUI

@main
struct HeartbeatAppApp: App {
    @StateObject private var audioManager = AudioEngineManager()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var tempo = TempoController()
    @StateObject private var sequencer = StepSequencerEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(audioManager)
                .environmentObject(locationManager)
                .environmentObject(tempo)
                .environmentObject(sequencer)
        }
    }
}
