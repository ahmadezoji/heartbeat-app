import AVFoundation
import WatchKit

/// Plays the run soundtrack at a tempo driven by running speed.
///
/// Source:
/// - If an audio file (mp3/m4a/wav/aiff/caf) is bundled in the app — e.g. dropped
///   into `HeartbeatWatch/Sounds/` — it loops with `AVAudioPlayer`, whose `rate`
///   follows the live tempo (watchOS has no AVAudioUnitTimePitch / Varispeed).
/// - Otherwise a synthesized "lub-dub" heartbeat is generated beat-by-beat.
///
/// Output:
/// - `useAirPods == true` uses the `.longFormAudio` route policy, which is the
///   only way watchOS routes app audio to AirPods / Bluetooth headphones. If none
///   is connected, watchOS shows its headphone picker automatically.
/// - Otherwise audio plays through the watch speaker.
final class BeatPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isStarting = false
    @Published private(set) var currentTempo: Double = TempoCalculator.defaultTempo
    @Published private(set) var statusText = "Ready."
    @Published var hapticsEnabled = true
    @Published var useAirPods = true

    /// Default soundtrack shipped in `HeartbeatWatch/Sounds/` and its measured tempo.
    static let defaultTrackName = "rythme1"
    static let defaultTrackBPM: Double = 126

    /// Bundled track, if any. `nil` → synthesized heartbeat.
    let musicURL: URL? = BeatPlayer.findBundledTrack()

    /// The track's native BPM, used as the initial base tempo so that at
    /// standstill the song plays at its normal speed.
    /// Base tempo range the UI should offer. Music playback rate is limited to
    /// 0.5×–2×, so for a song the range is derived from its BPM (126 → 63…200).
    var baseTempoRange: ClosedRange<Double> {
        musicURL == nil ? 40...200 : (nativeTempo * 0.5).rounded(.up)...min(200, nativeTempo * 2)
    }

    var nativeTempo: Double {
        musicURL?.deletingPathExtension().lastPathComponent == Self.defaultTrackName
            ? Self.defaultTrackBPM
            : TempoCalculator.defaultTempo
    }
    var trackName: String {
        musicURL?.deletingPathExtension().lastPathComponent ?? "Heartbeat (built-in)"
    }

    private let engine = AVAudioEngine()
    private let beatNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate: Double = 22_050
    private var musicPlayer: AVAudioPlayer?

    private var baseTempo = TempoCalculator.defaultTempo
    private var speedFactor = TempoCalculator.defaultSpeedFactor
    private var lastSpeed: Double = 0
    /// Incremented on every start/stop so stale callbacks are ignored.
    private var generation = 0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(beatNode)
        engine.connect(beatNode, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Control

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard !isPlaying, !isStarting else { return }
        isStarting = true
        statusText = useAirPods ? "Connecting headphones…" : "Starting…"
        generation += 1
        let startGeneration = generation

        activateSession { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self, startGeneration == self.generation else { return }
                self.isStarting = false
                guard success else {
                    self.statusText = error.map { "Audio: \($0.localizedDescription)" }
                        ?? "No headphones selected."
                    return
                }
                self.startOutput()
            }
        }
    }

    func stop() {
        generation += 1
        isStarting = false
        guard isPlaying else { return }
        isPlaying = false
        musicPlayer?.stop()
        musicPlayer = nil
        beatNode.stop()
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false)
        statusText = "Stopped."
    }

    // MARK: - Tempo

    func updateBaseTempo(_ tempo: Double) {
        baseTempo = tempo
        recalculateTempo()
    }

    func updateSpeedFactor(_ factor: Double) {
        speedFactor = factor
        recalculateTempo()
    }

    /// Safe to call from the background (wrist down) — not tied to the UI.
    func updateSpeed(_ metersPerSecond: Double) {
        lastSpeed = metersPerSecond
        recalculateTempo()
    }

    private func recalculateTempo() {
        currentTempo = TempoCalculator.calculateTempo(
            baseTempo: baseTempo,
            speedMetersPerSecond: lastSpeed,
            speedFactor: speedFactor
        )
        // Music: play relative to the track's real BPM, so both the Base control
        // and running speed change the playback speed (Base 140 on a 126 BPM
        // track → 1.11×). Comparing to baseTempo instead would always give 1.0×
        // when standing still, making the Base control have no audible effect.
        musicPlayer?.rate = Float(TempoCalculator.rate(for: currentTempo, baseTempo: nativeTempo))
    }

    // MARK: - Session / output

    private func activateSession(completion: @escaping (Bool, Error?) -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            if useAirPods {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                session.activate(options: [], completionHandler: completion)
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                completion(true, nil)
            }
        } catch {
            completion(false, error)
        }
    }

    private func startOutput() {
        if let url = musicURL {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true          // must be set before prepareToPlay
                player.numberOfLoops = -1
                player.prepareToPlay()
                musicPlayer = player
                recalculateTempo()
                player.play()
            } catch {
                statusText = "Can't play \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        } else {
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                statusText = "Audio error: \(error.localizedDescription)"
                return
            }
            isPlaying = true
            scheduleNextBeat(generation: generation)
            scheduleNextBeat(generation: generation)
            beatNode.play()
        }
        isPlaying = true
        statusText = useAirPods ? "Playing on headphones." : "Playing on speaker."
    }

    private static func findBundledTrack() -> URL? {
        for ext in ["mp3", "m4a", "wav"] {
            if let url = Bundle.main.url(forResource: defaultTrackName, withExtension: ext)
                ?? Bundle.main.url(forResource: defaultTrackName, withExtension: ext, subdirectory: "Sounds") {
                return url
            }
        }
        // Fallback: any other bundled audio file.
        let extensions = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
        let urls = extensions.flatMap { ext -> [URL] in
            (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Sounds") ?? [])
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    // MARK: - Synthesized heartbeat

    private func scheduleNextBeat(generation scheduledGeneration: Int) {
        guard isPlaying, scheduledGeneration == generation else { return }
        let buffer = makeBeatBuffer(bpm: currentTempo)
        beatNode.scheduleBuffer(buffer) { [weak self] in
            // Called on an audio thread once the buffer has been consumed.
            DispatchQueue.main.async {
                guard let self = self, self.isPlaying, scheduledGeneration == self.generation else { return }
                if self.hapticsEnabled {
                    WKInterfaceDevice.current().play(.click)
                }
                self.scheduleNextBeat(generation: scheduledGeneration)
            }
        }
    }

    /// One beat period of audio: a low "lub", a softer "dub", then silence.
    private func makeBeatBuffer(bpm: Double) -> AVAudioPCMBuffer {
        let period = 60.0 / max(bpm, 1)
        let frameCount = AVAudioFrameCount(period * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { samples[i] = 0 }

        // Small watch speakers can't reproduce real heartbeat sub-bass,
        // so use audible low-mid frequencies with a harmonic for punch.
        writeThump(into: samples, frameCount: Int(frameCount), start: 0,
                   frequency: 140, duration: 0.11, amplitude: 0.9)
        let dubOffset = min(0.28, period * 0.35)
        writeThump(into: samples, frameCount: Int(frameCount), start: Int(dubOffset * sampleRate),
                   frequency: 110, duration: 0.09, amplitude: 0.6)
        return buffer
    }

    private func writeThump(into samples: UnsafeMutablePointer<Float>, frameCount: Int, start: Int,
                            frequency: Double, duration: Double, amplitude: Double) {
        let length = min(Int(duration * sampleRate), frameCount - start)
        guard length > 0 else { return }
        for n in 0..<length {
            let t = Double(n) / sampleRate
            let attack = min(1, t / 0.005)              // 5 ms fade-in avoids clicks
            let decay = exp(-t * 35)                      // fast exponential decay
            let wave = sin(2 * .pi * frequency * t) + 0.5 * sin(2 * .pi * frequency * 2 * t)
            samples[start + n] += Float(amplitude * attack * decay * wave / 1.5)
        }
    }
}
