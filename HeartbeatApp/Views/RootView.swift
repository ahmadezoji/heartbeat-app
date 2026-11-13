import SwiftUI

struct RootView: View {
    @EnvironmentObject private var audioManager: AudioEngineManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var tempo: TempoController
    @EnvironmentObject private var sequencer: StepSequencerEngine

    @State private var showHome = false

    var body: some View {
        ZStack {
            if showHome {
                TabView {
                    HomeView()
                        .tabItem { Label("Home", systemImage: "heart.fill") }
                    ComposeView()
                        .tabItem { Label("Compose", systemImage: "square.grid.3x3.fill") }
                }
                .tint(Color("AccentColor"))
            } else {
                SplashView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            locationManager.requestAuthorization()
            locationManager.startTracking()
            audioManager.updateTempo(tempo.currentTempo)
            sequencer.setTempo(tempo.currentTempo)
            DispatchQueue.global(qos: .utility).async { SoundLibrary.shared.preload() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeInOut) {
                    showHome = true
                }
            }
        }
        // Tempo is shared by both tabs: speed → tempo controller → both players.
        .onChange(of: locationManager.speedMetersPerSecond) { tempo.updateSpeed($0) }
        .onChange(of: tempo.currentTempo) { bpm in
            audioManager.updateTempo(bpm)
            sequencer.setTempo(bpm)
        }
        // Only one source of music at a time: the Home track or the Compose loop.
        .onChange(of: audioManager.isPlaying) { if $0 { sequencer.stop() } }
        .onChange(of: sequencer.isPlaying) { if $0 { audioManager.stop() } }
    }
}

#Preview {
    RootView()
        .environmentObject(AudioEngineManager())
        .environmentObject(LocationManager())
        .environmentObject(TempoController())
        .environmentObject(StepSequencerEngine())
}
