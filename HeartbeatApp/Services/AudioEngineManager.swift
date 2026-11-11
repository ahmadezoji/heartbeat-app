import AVFoundation
import SwiftUI

final class AudioEngineManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrackName = "No track loaded"
    @Published private(set) var statusText = "Import a rhythmic loop to begin."
    @Published private(set) var currentTempo: Double = TempoCalculator.defaultTempo
    /// The loaded track's own tempo (playback rate 1.0×). Base Tempo and speed
    /// are applied relative to this, so changing Base Tempo is audible even
    /// when standing still.
    @Published private(set) var trackTempo: Double = TempoCalculator.defaultTempo

    /// Default soundtrack bundled in SharedAudio/ (shared with the watch app).
    static let defaultTrackName = "rythme1"
    static let defaultTrackBPM: Double = 126

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioBuffer: AVAudioPCMBuffer?
    private var baseTempo = TempoCalculator.defaultTempo
    private var speedFactor = TempoCalculator.defaultSpeedFactor
    private var lastSpeed: Double = 0

    init() {
        configureAudioSession()
        configureEngine()
        loadDefaultTrack()
    }

    /// Loads the bundled default track so the app plays out of the box.
    func loadDefaultTrack() {
        guard let url = Bundle.main.url(forResource: Self.defaultTrackName, withExtension: "mp3") else { return }
        if loadFile(at: url, displayName: "Rhythm 1 (default)") {
            trackTempo = Self.defaultTrackBPM
            applyTempo()
        }
    }

    func loadAudio(from url: URL) {
        stop()
        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let fileURL = try makeLocalCopyIfNeeded(from: url)
            if loadFile(at: fileURL, displayName: url.lastPathComponent) {
                // An imported track's BPM is unknown: treat the current Base Tempo
                // as its natural speed, so it starts at 1.0× and Base changes from there.
                trackTempo = baseTempo
                applyTempo()
            }
        } catch {
            setError("Failed to load audio: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func loadFile(at fileURL: URL, displayName: String) -> Bool {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                setError("Unable to create audio buffer.")
                return false
            }
            try file.read(into: buffer)
            audioBuffer = buffer
            currentTrackName = displayName
            statusText = "Ready to play."
            return true
        } catch {
            setError("Failed to load audio: \(error.localizedDescription)")
            return false
        }
    }

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard let buffer = audioBuffer else {
            setError("Please import a loopable audio file first.")
            return
        }

        if !engine.isRunning {
            try? engine.start()
        }

        if !playerNode.isPlaying {
            playerNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            playerNode.play()
            isPlaying = true
            statusText = "Playing in loop."
        }
    }

    func stop() {
        playerNode.stop()
        isPlaying = false
        statusText = "Stopped."
    }

    func updateBaseTempo(_ tempo: Double) {
        baseTempo = tempo
        applyTempo()
    }

    func updateSpeedFactor(_ factor: Double) {
        speedFactor = factor
        applyTempo()
    }

    func updateSpeed(_ speed: Double) {
        lastSpeed = speed
        applyTempo()
    }

    func setError(_ message: String) {
        statusText = message
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusText = "Audio session error: \(error.localizedDescription)"
        }
    }

    private func configureEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.rate = 1.0
    }

    private func makeLocalCopyIfNeeded(from url: URL) throws -> URL {
        if url.isFileURL == false {
            return url
        }

        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) == false {
            try FileManager.default.copyItem(at: url, to: destURL)
        }
        return destURL
    }

    private func applyTempo() {
        let newTempo = TempoCalculator.calculateTempo(
            baseTempo: baseTempo,
            speedMetersPerSecond: lastSpeed,
            speedFactor: speedFactor
        )
        currentTempo = newTempo

        // Relative to the track's own tempo (not baseTempo), otherwise the rate
        // is always 1.0× when standing still and Base Tempo has no audible effect.
        let rate = TempoCalculator.rate(for: newTempo, baseTempo: trackTempo)
        timePitch.rate = Float(rate)
        if isPlaying {
            statusText = "Playing at \(Int(newTempo)) BPM."
        }
    }
}
