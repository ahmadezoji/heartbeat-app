import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var audioManager: AudioEngineManager
    @EnvironmentObject private var locationManager: LocationManager

    @State private var showImporter = false
    @State private var baseTempo: Double = TempoCalculator.defaultTempo
    @State private var speedFactor: Double = TempoCalculator.defaultSpeedFactor

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    audioSection
                    tempoSection
                    locationSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    audioManager.loadAudio(from: url)
                }
            case .failure(let error):
                audioManager.setError(error.localizedDescription)
            }
        }
        .onChange(of: baseTempo) { newValue in
            audioManager.updateBaseTempo(newValue)
        }
        .onChange(of: speedFactor) { newValue in
            audioManager.updateSpeedFactor(newValue)
        }
        .onChange(of: locationManager.speedMetersPerSecond) { newValue in
            audioManager.updateSpeed(newValue)
        }
        .onAppear {
            audioManager.updateBaseTempo(baseTempo)
            audioManager.updateSpeedFactor(speedFactor)
            locationManager.requestAuthorization()
            locationManager.startTracking()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adaptive Loop Player")
                .font(.title.bold())
                .foregroundStyle(.primary)
            Text("Import a rhythmic loop (wav, mp3, aiff) and let your speed change the tempo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio")
                .font(.headline)
            HStack {
                VStack(alignment: .leading) {
                    Text(audioManager.currentTrackName)
                        .font(.subheadline.bold())
                    Text(audioManager.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    audioManager.togglePlayback()
                } label: {
                    Label(audioManager.isPlaying ? "Stop" : "Play", systemImage: audioManager.isPlaying ? "stop.fill" : "play.fill")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tempo")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base Tempo")
                        .font(.subheadline)
                    Text("\(Int(baseTempo)) BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(value: $baseTempo, in: 40...140, step: 1) {
                    EmptyView()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Speed Influence")
                    .font(.subheadline)
                Slider(value: $speedFactor, in: 0...12, step: 0.5)
                Text("+\(speedFactor, specifier: "%.1f") BPM per m/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Tempo")
                        .font(.subheadline)
                    Text("\(Int(audioManager.currentTempo)) BPM")
                        .font(.title3.bold())
                }
                Spacer()
                Image(systemName: "metronome.fill")
                    .font(.title2)
                    .foregroundStyle(.accent)
            }
        }
        .padding()
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location & Speed")
                .font(.headline)
            Text(locationManager.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Label("\(locationManager.speedMetersPerSecond, specifier: "%.2f") m/s", systemImage: "location.fill")
                    .font(.subheadline)
                Spacer()
                Label("\(locationManager.speedKilometersPerHour, specifier: "%.1f") km/h", systemImage: "speedometer")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    HomeView()
        .environmentObject(AudioEngineManager())
        .environmentObject(LocationManager())
}
