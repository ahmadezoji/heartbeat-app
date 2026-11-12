import SwiftUI

struct WatchHomeView: View {
    @EnvironmentObject private var beatPlayer: BeatPlayer
    @EnvironmentObject private var workout: WorkoutManager

    @State private var baseTempo: Double = TempoCalculator.defaultTempo
    @State private var speedFactor: Double = TempoCalculator.defaultSpeedFactor
    @State private var pulse = false
    @State private var didSetInitialTempo = false
    @AppStorage("tempoSource") private var tempoSourceRaw = BeatPlayer.TempoSource.location.rawValue

    private var tempoSource: BeatPlayer.TempoSource {
        BeatPlayer.TempoSource(rawValue: tempoSourceRaw) ?? .location
    }

    private let accent = Color("AccentColor")

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                tempoHeader
                startButton
                statsRow
                sourcePicker
                if tempoSource == .location {
                    baseTempoRow
                    speedFactorRow
                } else {
                    Text("Music follows your heart rate")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Toggle("AirPods / headphones", isOn: $beatPlayer.useAirPods)
                    .font(.footnote)
                    .disabled(isRunning)
                if beatPlayer.musicURL == nil {
                    Toggle("Haptic beat", isOn: $beatPlayer.hapticsEnabled)
                        .font(.footnote)
                }
                Text(beatPlayer.trackName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                Text("\(beatPlayer.statusText) \(workout.statusText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            if !didSetInitialTempo {
                baseTempo = beatPlayer.nativeTempo
                didSetInitialTempo = true
            }
            beatPlayer.updateBaseTempo(baseTempo)
            beatPlayer.updateSpeedFactor(speedFactor)
            beatPlayer.tempoSource = tempoSource
            // Direct model-to-model link so tempo follows speed with the screen off.
            let player = beatPlayer
            workout.onSpeedChange = { [weak player] speed in player?.updateSpeed(speed) }
            workout.onHeartRateChange = { [weak player] bpm in player?.updateHeartRate(bpm) }
            workout.requestAuthorization()
        }
        .onChange(of: baseTempo) { beatPlayer.updateBaseTempo($0) }
        .onChange(of: speedFactor) { beatPlayer.updateSpeedFactor($0) }
        .onChange(of: tempoSourceRaw) { _ in beatPlayer.tempoSource = tempoSource }
    }

    private var isRunning: Bool {
        beatPlayer.isPlaying || beatPlayer.isStarting || workout.isActive
    }

    private var tempoHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "heart.fill")
                .foregroundColor(accent)
                .scaleEffect(pulse ? 1.2 : 0.9)
                .animation(
                    beatPlayer.isPlaying
                        ? .easeInOut(duration: 30 / beatPlayer.currentTempo).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            Text("\(Int(beatPlayer.currentTempo))")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("BPM")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var startButton: some View {
        Button {
            if isRunning {
                beatPlayer.stop()
                workout.stop()
                pulse = false
            } else {
                workout.start()
                beatPlayer.play()
                pulse = true
            }
        } label: {
            Label(isRunning ? "Stop" : "Start",
                  systemImage: isRunning ? "stop.fill" : "play.fill")
        }
        .tint(isRunning ? .gray : accent)
    }

    private var statsRow: some View {
        HStack {
            Label("\(workout.speedKilometersPerHour, specifier: "%.1f") km/h", systemImage: "speedometer")
            Spacer()
            Label(workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "--", systemImage: "waveform.path.ecg")
        }
        .font(.caption2)
    }

    /// Radio-style choice: exactly one source drives the tempo.
    private var sourcePicker: some View {
        HStack(spacing: 6) {
            sourceButton(.location, title: "Speed", icon: "location.fill")
            sourceButton(.heartRate, title: "Heart", icon: "heart.fill")
        }
    }

    private func sourceButton(_ source: BeatPlayer.TempoSource, title: String, icon: String) -> some View {
        let selected = tempoSource == source
        return Button {
            tempoSourceRaw = source.rawValue
        } label: {
            Label(title, systemImage: icon)
                .font(.caption2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? accent : Color.gray.opacity(0.25))
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var baseTempoRow: some View {
        HStack {
            Button { baseTempo = max(beatPlayer.baseTempoRange.lowerBound, baseTempo - 2) } label: { Image(systemName: "minus") }
                .frame(width: 40)
            VStack(spacing: 0) {
                Text("Base").font(.caption2).foregroundColor(.secondary)
                Text("\(Int(baseTempo))").font(.headline)
            }
            .frame(maxWidth: .infinity)
            Button { baseTempo = min(beatPlayer.baseTempoRange.upperBound, baseTempo + 2) } label: { Image(systemName: "plus") }
                .frame(width: 40)
        }
        .buttonStyle(.bordered)
    }

    private var speedFactorRow: some View {
        VStack(spacing: 2) {
            Text("+\(speedFactor, specifier: "%.1f") BPM per m/s")
                .font(.caption2)
                .foregroundColor(.secondary)
            Slider(value: $speedFactor, in: 0...12, step: 0.5)
        }
    }
}

struct WatchHomeView_Previews: PreviewProvider {
    static var previews: some View {
        WatchHomeView()
            .environmentObject(BeatPlayer())
            .environmentObject(WorkoutManager())
    }
}
