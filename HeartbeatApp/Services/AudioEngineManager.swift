import AVFoundation
import SwiftUI

final class AudioEngineManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrackName = "No track loaded"
    @Published private(set) var statusText = "Import a rhythmic loop to begin."
    @Published private(set) var currentTempo: Double = TempoCalculator.defaultTempo

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioBuffer: AVAudioPCMBuffer?
    private var baseTempo = TempoCalculator.defaultTempo
    private var speedFactor = TempoCalculator.defaultSpeedFactor

    init() {
        configureAudioSession()
        configureEngine()
    }

    func loadAudio(from url: URL) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                setError("Unable to create audio buffer.")
                return
            }
            try file.read(into: buffer)
            audioBuffer = buffer
            currentTrackName = url.lastPathComponent
            statusText = "Ready to play."
        } catch {
            setError("Failed to load audio: \(error.localizedDescription)")
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
        applyTempo(speedMetersPerSecond: 0)
    }

    func updateSpeedFactor(_ factor: Double) {
        speedFactor = factor
        applyTempo(speedMetersPerSecond: 0)
    }

    func updateSpeed(_ speed: Double) {
        applyTempo(speedMetersPerSecond: speed)
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

    private func applyTempo(speedMetersPerSecond: Double) {
        let newTempo = TempoCalculator.calculateTempo(
            baseTempo: baseTempo,
            speedMetersPerSecond: speedMetersPerSecond,
            speedFactor: speedFactor
        )
        currentTempo = newTempo

        let rate = TempoCalculator.rate(for: newTempo, baseTempo: baseTempo)
        timePitch.rate = Float(rate)
        if isPlaying {
            statusText = "Playing at \(Int(newTempo)) BPM."
        }
    }
}
