import AVFoundation
import SwiftUI
import os

/// Step sequencer for the Compose tab.
///
/// All timing happens on the audio render thread (`SequencerRenderer`), counted in
/// samples, so steps stay sample-accurate and follow tempo changes immediately.
/// The main thread only edits `rows` and pushes immutable snapshots to the renderer.
final class StepSequencerEngine: ObservableObject {
    enum Transport { case stopped, playing, paused }

    @Published private(set) var transport: Transport = .stopped
    @Published private(set) var rows: [SequencerRow] = []
    /// Step under the playhead, as heard (output latency compensated). nil when stopped.
    @Published private(set) var currentStep: Int?
    @Published private(set) var tempo: Double = TempoCalculator.defaultTempo

    var isPlaying: Bool { transport == .playing }

    private let engine = AVAudioEngine()
    private let renderer = SequencerRenderer()
    private var sourceNode: AVAudioSourceNode?
    private var playheadTimer: Timer?
    private var recordedCount = 0

    init() {
        rows = DefaultKits.drumRows() + DefaultKits.synthRows()
        configureEngine()
        pushRows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(engineConfigurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    // MARK: - Transport

    func play() {
        guard transport != .playing else { return }
        guard startEngineIfNeeded() else { return }
        renderer.send(.play)
        transport = .playing
        startPlayheadTimer()
    }

    func pause() {
        guard transport == .playing else { return }
        renderer.send(.pause)
        transport = .paused
        stopPlayheadTimer()
    }

    func stop() {
        guard transport != .stopped else { return }
        renderer.send(.stop)
        transport = .stopped
        stopPlayheadTimer()
        currentStep = nil
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func setTempo(_ bpm: Double) {
        tempo = bpm
        renderer.send(.tempo(bpm))
    }

    /// Lowers the sequencer while the mic is recording through the speaker,
    /// so the beat doesn't drown out the user's sound.
    func setDucked(_ ducked: Bool) {
        renderer.send(.masterGain(ducked ? 0.25 : 1))
    }

    /// Plays one sound once, e.g. to preview a suggestion.
    func preview(_ sound: SampleBuffer, rate: Float = 1) {
        guard startEngineIfNeeded() else { return }
        renderer.send(.oneShot(sound, rate))
    }

    // MARK: - Editing

    func rows(in group: RowGroup) -> [SequencerRow] { rows.filter { $0.group == group } }

    func toggle(rowID: UUID, step: Int) {
        guard let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[i].steps[step].toggle()
        pushRows()
        // Audition the sound when a pad is switched on and nothing is playing.
        if rows[i].steps[step], !isPlaying {
            preview(rows[i].sound, rate: rows[i].rates[step])
        }
    }

    func clear(rowID: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[i].steps = Array(repeating: false, count: StepGrid.stepCount)
        pushRows()
    }

    func clearAll() {
        for i in rows.indices { rows[i].steps = Array(repeating: false, count: StepGrid.stepCount) }
        pushRows()
    }

    func remove(rowID: UUID) {
        rows.removeAll { $0.id == rowID }
        pushRows()
    }

    func setVolume(rowID: UUID, volume: Float) {
        guard let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[i].volume = volume
        pushRows()
    }

    @discardableResult
    func addRecordedRow(name: String, symbol: String, sound: SampleBuffer, steps: [Bool], rates: [Float]) -> SequencerRow {
        recordedCount += 1
        let hue = (0.08 + Double(recordedCount) * 0.17).truncatingRemainder(dividingBy: 1)
        let row = SequencerRow(name: name, symbol: symbol,
                               color: Color(hue: hue, saturation: 0.65, brightness: 0.95),
                               group: .recorded, sound: sound, steps: steps, rates: rates)
        rows.append(row)
        pushRows()
        return row
    }

    // MARK: - Timing (for aligning recordings to the grid)

    /// Where the playhead was (in steps, continuous, not wrapped) when the
    /// sound that reaches the listener at `hostSeconds` was rendered.
    /// nil if the sequencer isn't playing.
    func stepPosition(atHostSeconds hostSeconds: Double) -> Double? {
        guard isPlaying, let anchor = renderer.timingAnchor() else { return nil }
        let heardAt = anchor.hostSeconds + AVAudioSession.sharedInstance().outputLatency
        let stepsPerSecond = 1 / StepGrid.stepDuration(bpm: anchor.bpm)
        return anchor.stepPosition + (hostSeconds - heardAt) * stepsPerSecond
    }

    // MARK: - Private

    private func pushRows() {
        renderer.send(.rows(rows.map {
            RenderRow(sound: $0.sound, steps: $0.steps, rates: $0.rates, gain: $0.volume)
        }))
    }

    private func configureEngine() {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        renderer.sampleRate = sampleRate
        let renderer = self.renderer
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList in
            renderer.render(frameCount: Int(frameCount), timestamp: timestamp, bufferList: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Route or category changes (e.g. switching to record mode, plugging in
    /// headphones) stop the engine; restart it if we were playing.
    @objc private func engineConfigurationChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.transport == .playing { self.startEngineIfNeeded() }
        }
    }

    private func startPlayheadTimer() {
        stopPlayheadTimer()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.refreshPlayhead()
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func refreshPlayhead() {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guard let position = stepPosition(atHostSeconds: now) else { return }
        let step = StepGrid.wrap(Int(floor(position)))
        if step != currentStep { currentStep = step }
    }
}

// MARK: - Render thread

struct RenderRow {
    let sound: SampleBuffer
    let steps: [Bool]
    let rates: [Float]
    let gain: Float
}

/// Owns everything the audio thread touches. The main thread talks to it only
/// through `send(_:)`, which queues commands behind a lock; the render thread
/// drains them with `trylock`, so it never blocks.
final class SequencerRenderer {
    enum Command {
        case play, pause, stop
        case tempo(Double)
        case rows([RenderRow])
        case masterGain(Float)
        case oneShot(SampleBuffer, Float)
    }

    struct TimingAnchor {
        let hostSeconds: Double
        let stepPosition: Double
        let bpm: Double
    }

    var sampleRate: Double = 44_100

    private struct Voice {
        var sound: SampleBuffer?
        var position: Double = 0
        var increment: Double = 1
        var gain: Float = 1
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    // Guarded by `lock`.
    private var pending: [Command] = []
    private var anchor: TimingAnchor?

    // Render-thread only.
    private var rows: [RenderRow] = []
    private var voices = [Voice](repeating: Voice(), count: 48)
    private var nextVoice = 0
    private var running = false
    private var bpm: Double = TempoCalculator.defaultTempo
    private var masterGain: Float = 1
    /// Absolute index of the next step to fire (not wrapped).
    private var nextStep = 0
    private var samplesUntilNextStep: Double = 0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending.reserveCapacity(64)
    }

    deinit { lock.deallocate() }

    func send(_ command: Command) {
        os_unfair_lock_lock(lock)
        pending.append(command)
        os_unfair_lock_unlock(lock)
    }

    func timingAnchor() -> TimingAnchor? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return anchor
    }

    func render(frameCount: Int, timestamp: UnsafePointer<AudioTimeStamp>,
                bufferList: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(lock) {
            for command in pending { apply(command) }
            pending.removeAll(keepingCapacity: true)
            if running, timestamp.pointee.mFlags.contains(.hostTimeValid) {
                let samplesPerStep = sampleRate * StepGrid.stepDuration(bpm: bpm)
                anchor = TimingAnchor(
                    hostSeconds: AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime),
                    stepPosition: Double(nextStep) - samplesUntilNextStep / samplesPerStep,
                    bpm: bpm)
            }
            os_unfair_lock_unlock(lock)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let stepSamples = sampleRate * StepGrid.stepDuration(bpm: bpm)

        for frame in 0..<frameCount {
            if running {
                if samplesUntilNextStep <= 0 {
                    triggerStep(StepGrid.wrap(nextStep))
                    nextStep += 1
                    samplesUntilNextStep += stepSamples
                }
                samplesUntilNextStep -= 1
            }

            var mix: Float = 0
            for v in voices.indices {
                guard let sound = voices[v].sound else { continue }
                let pos = voices[v].position
                let i = Int(pos)
                if i >= sound.count - 1 {
                    voices[v].sound = nil
                    continue
                }
                let frac = Float(pos - Double(i))
                let s = sound.data[i] * (1 - frac) + sound.data[i + 1] * frac
                mix += s * voices[v].gain
                voices[v].position = pos + voices[v].increment
            }
            out[frame] = max(-1, min(1, mix * 0.7 * masterGain))
        }
        // Mono source; copy into any extra channels.
        for b in 1..<buffers.count {
            if let dst = buffers[b].mData { memcpy(dst, out, frameCount * MemoryLayout<Float>.size) }
        }
    }

    private func apply(_ command: Command) {
        switch command {
        case .play:
            running = true
        case .pause:
            running = false
        case .stop:
            running = false
            nextStep = 0
            samplesUntilNextStep = 0
            anchor = nil
        case .tempo(let newBPM):
            // Keep the playhead's phase within the current step when tempo changes.
            let oldStep = sampleRate * StepGrid.stepDuration(bpm: bpm)
            let newStep = sampleRate * StepGrid.stepDuration(bpm: newBPM)
            samplesUntilNextStep *= newStep / oldStep
            bpm = newBPM
        case .rows(let newRows):
            rows = newRows
        case .masterGain(let gain):
            masterGain = gain
        case .oneShot(let sound, let rate):
            startVoice(sound, rate: rate, gain: 1)
        }
    }

    private func triggerStep(_ step: Int) {
        for row in rows where row.steps[step] {
            startVoice(row.sound, rate: row.rates[step], gain: row.gain)
        }
    }

    private func startVoice(_ sound: SampleBuffer, rate: Float, gain: Float) {
        voices[nextVoice] = Voice(sound: sound, position: 0,
                                  increment: Double(rate) * sound.sampleRate / sampleRate,
                                  gain: gain)
        nextVoice = (nextVoice + 1) % voices.count
    }
}
