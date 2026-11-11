import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var audioManager: AudioEngineManager
    @EnvironmentObject private var locationManager: LocationManager

    @State private var showImporter = false
    @State private var baseTempo: Double = TempoCalculator.defaultTempo
    @State private var speedFactor: Double = TempoCalculator.defaultSpeedFactor
    @State private var didSetInitialTempo = false
    @State private var pulse = false

    private let accent = Color("AccentColor")
    private let tempoRange: ClosedRange<Double> = 40...200

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [accent.opacity(0.45), Color.black, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        playerCard
                        baseTempoCard
                        speedCard
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Heartbeat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
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
        .onChange(of: audioManager.isPlaying) { playing in
            pulse = playing
        }
        .onAppear {
            if !didSetInitialTempo {
                // Start at the loaded track's own tempo (126 BPM for the default song).
                baseTempo = audioManager.trackTempo
                didSetInitialTempo = true
            }
            audioManager.updateBaseTempo(baseTempo)
            audioManager.updateSpeedFactor(speedFactor)
            locationManager.requestAuthorization()
            locationManager.startTracking()
        }
    }

    // MARK: - Player

    private var playbackRate: Double {
        TempoCalculator.rate(for: audioManager.currentTempo, baseTempo: audioManager.trackTempo)
    }

    private var playerCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.headline)
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.15))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(audioManager.currentTrackName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Original tempo \(Int(audioManager.trackTempo)) BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.title)
                        .foregroundStyle(accent)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .animation(
                            audioManager.isPlaying
                                ? .easeInOut(duration: 30 / max(audioManager.currentTempo, 1)).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Text("\(Int(audioManager.currentTempo))")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.2f× speed", playbackRate))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                audioManager.togglePlayback()
            } label: {
                Label(audioManager.isPlaying ? "Stop" : "Play",
                      systemImage: audioManager.isPlaying ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(audioManager.isPlaying ? Color.white.opacity(0.15) : accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Text(audioManager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - Base tempo

    private var baseTempoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Base tempo", subtitle: "Your tempo when standing still")
            HStack {
                roundButton("minus") { baseTempo = max(tempoRange.lowerBound, baseTempo - 2) }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(baseTempo))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("BPM")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                roundButton("plus") { baseTempo = min(tempoRange.upperBound, baseTempo + 2) }
            }
        }
        .card()
    }

    // MARK: - Speed

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Speed influence", subtitle: "How much running faster raises the tempo")
            Slider(value: $speedFactor, in: 0...12, step: 0.5)
                .tint(accent)
            HStack {
                Text("+\(speedFactor, specifier: "%.1f") BPM per m/s")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                // At 10 km/h (≈ 2.78 m/s) — makes the slider's effect visible while standing still.
                Text("At 10 km/h: +\(Int((speedFactor * 10 / 3.6).rounded())) BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().overlay(Color.white.opacity(0.1))

            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(0.15))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(locationManager.speedKilometersPerHour, specifier: "%.1f") km/h")
                        .font(.title3.bold().monospacedDigit())
                    Text("\(locationManager.speedMetersPerSecond, specifier: "%.2f") m/s · \(locationManager.statusText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .card()
    }

    // MARK: - Helpers

    private func cardTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func roundButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.bold())
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.1))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
    }
}

private extension View {
    /// Translucent card used for every section on the home screen.
    func card() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

#Preview {
    HomeView()
        .environmentObject(AudioEngineManager())
        .environmentObject(LocationManager())
}
