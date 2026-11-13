import AVFoundation

/// Captures a few seconds of microphone audio while the sequencer keeps playing.
///
/// Uses its own `AVAudioEngine` so recording never disturbs the sequencer graph.
/// The session is switched to `.playAndRecord` with A2DP allowed, so AirPods keep
/// high-quality playback while the iPhone's built-in mic does the recording.
final class SoundRecorder: ObservableObject {
    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        /// Host time (seconds) at which the first sample hit the microphone.
        let startHostSeconds: Double
    }

    enum RecorderError: LocalizedError {
        case permissionDenied, noInput
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access is off. Enable it in Settings › Heartbeat."
            case .noInput: return "No microphone available."
            }
        }
    }

    static let maxDuration: TimeInterval = 5

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Input level 0…1 for a simple meter.
    @Published private(set) var level: Float = 0

    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "SoundRecorder.samples")
    private var samples: [Float] = []
    private var sampleRate: Double = 44_100
    private var startHostSeconds: Double?
    private var startDate: Date?
    private var timer: Timer?
    private var autoStopHandler: (() -> Void)?

    var isUsingSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    /// Asks for microphone permission. Completion runs on the main queue.
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: completion(true)
        case .denied: completion(false)
        default:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// Starts recording. `onAutoStop` is called if the max duration is reached.
    func start(onAutoStop: @escaping () -> Void) throws {
        guard !isRecording else { return }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw RecorderError.permissionDenied
        }
        try Self.enableRecordingSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noInput }

        queue.sync {
            samples = []
            samples.reserveCapacity(Int(format.sampleRate * Self.maxDuration))
            startHostSeconds = nil
        }
        sampleRate = format.sampleRate
        let maxSamples = Int(format.sampleRate * Self.maxDuration)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<count { peak = max(peak, abs(channel[i])) }
            self.queue.async {
                if self.startHostSeconds == nil, time.isHostTimeValid {
                    self.startHostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
                        - AVAudioSession.sharedInstance().inputLatency
                }
                let room = maxSamples - self.samples.count
                if room > 0 {
                    self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(count, room)))
                }
            }
            DispatchQueue.main.async { self.level = min(1, peak * 1.5) }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        autoStopHandler = onAutoStop
        isRecording = true
        elapsed = 0
        startDate = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            self.elapsed = Date().timeIntervalSince(start)
            if self.elapsed >= Self.maxDuration { self.autoStopHandler?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops recording and returns what was captured (nil if nothing).
    func stop() -> Recording? {
        guard isRecording, let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        timer?.invalidate()
        timer = nil
        autoStopHandler = nil
        isRecording = false
        level = 0

        let (captured, start) = queue.sync { (samples, startHostSeconds) }
        guard !captured.isEmpty else { return nil }
        return Recording(samples: captured, sampleRate: sampleRate,
                         startHostSeconds: start ?? AVAudioTime.seconds(forHostTime: mach_absolute_time()))
    }

    /// Switches the shared session to play-and-record once; it stays that way so
    /// later recordings don't interrupt playback again with another route change.
    static func enableRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try session.setActive(true)
    }
}
