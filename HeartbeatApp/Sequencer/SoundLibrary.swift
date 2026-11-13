import Foundation

/// An immutable mono sample the sequencer can trigger.
///
/// The audio thread reads `data` directly, so the storage is a raw pointer that
/// never changes after init.
final class SampleBuffer {
    let data: UnsafeMutablePointer<Float>
    let count: Int
    let sampleRate: Double
    /// MIDI note the sample sounds at when played at rate 1.0 (used for pitching).
    let baseNote: Double

    init(samples: [Float], sampleRate: Double, baseNote: Double = 60) {
        let count = max(samples.count, 2)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
        for (i, value) in samples.enumerated() { storage[i] = value }
        self.count = count
        self.data = storage
        self.sampleRate = sampleRate
        self.baseNote = baseNote
    }

    deinit { data.deallocate() }

    /// Playback rate that makes this sample sound at `midiNote`.
    func rate(forNote midiNote: Double) -> Float {
        Float(pow(2, (midiNote - baseNote) / 12))
    }
}

/// Built-in sounds, synthesized in code so the app needs no extra audio assets.
enum SoundID: String, CaseIterable, Identifiable {
    // Drum kit
    case kick, snare, clap, hihat, shaker, cowbell, conga
    // Melodic
    case keys, pluck, bell, bass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .clap: return "Clap"
        case .hihat: return "Hi-hat"
        case .shaker: return "Shaker"
        case .cowbell: return "Cowbell"
        case .conga: return "Conga"
        case .keys: return "Keys"
        case .pluck: return "Pluck"
        case .bell: return "Bell"
        case .bass: return "Bass"
        }
    }

    var symbol: String {
        switch self {
        case .kick: return "circle.fill"
        case .snare: return "circle.circle"
        case .clap: return "hands.clap.fill"
        case .hihat: return "triangle"
        case .shaker: return "aqi.medium"
        case .cowbell: return "bell"
        case .conga: return "cylinder.fill"
        case .keys: return "pianokeys"
        case .pluck: return "guitars"
        case .bell: return "bell.fill"
        case .bass: return "speaker.wave.3.fill"
        }
    }

    var isMelodic: Bool {
        switch self {
        case .keys, .pluck, .bell, .bass: return true
        default: return false
        }
    }
}

final class SoundLibrary {
    static let shared = SoundLibrary()
    static let sampleRate: Double = 44_100

    private var cache: [SoundID: SampleBuffer] = [:]
    private let lock = NSLock()

    func sound(_ id: SoundID) -> SampleBuffer {
        lock.lock(); defer { lock.unlock() }
        if let buffer = cache[id] { return buffer }
        let buffer = Self.synthesize(id)
        cache[id] = buffer
        return buffer
    }

    /// Builds every sound up front so the first tap doesn't stall.
    func preload() {
        SoundID.allCases.forEach { _ = sound($0) }
    }

    // MARK: - Synthesis

    private static func synthesize(_ id: SoundID) -> SampleBuffer {
        let sr = sampleRate
        switch id {
        case .kick:
            return SampleBuffer(samples: render(0.45) { t, phase in
                // Pitch sweep 150 → 50 Hz gives the classic electronic kick.
                let f = 50 + 100 * exp(-t * 30)
                phase += 2 * .pi * f / sr
                let click = t < 0.004 ? (1 - t / 0.004) * 0.4 : 0
                return sin(phase) * exp(-t * 7) + click
            }, sampleRate: sr)

        case .snare:
            var noise = NoiseGenerator()
            var hp = HighPass(cutoff: 1_500, sampleRate: sr)
            return SampleBuffer(samples: render(0.28) { t, phase in
                phase += 2 * .pi * 185 / sr
                let body = sin(phase) * exp(-t * 28) * 0.55
                let rattle = hp.process(noise.next()) * exp(-t * 17) * 0.8
                return body + rattle
            }, sampleRate: sr)

        case .clap:
            var noise = NoiseGenerator()
            var bp = BandPass(center: 1_200, q: 0.9, sampleRate: sr)
            return SampleBuffer(samples: render(0.35) { t, _ in
                // Three quick bursts then a tail — sounds like several hands.
                var env = 0.0
                for offset in [0.0, 0.011, 0.022] where t >= offset {
                    env = max(env, exp(-(t - offset) * 140))
                }
                if t >= 0.022 { env = max(env, 0.6 * exp(-(t - 0.022) * 14)) }
                return bp.process(noise.next()) * env * 2.2
            }, sampleRate: sr)

        case .hihat:
            var noise = NoiseGenerator()
            var hp = HighPass(cutoff: 7_000, sampleRate: sr)
            return SampleBuffer(samples: render(0.11) { t, _ in
                hp.process(noise.next()) * exp(-t * 45) * 0.9
            }, sampleRate: sr)

        case .shaker:
            var noise = NoiseGenerator()
            var hp = HighPass(cutoff: 4_500, sampleRate: sr)
            return SampleBuffer(samples: render(0.14) { t, _ in
                let env = min(1, t / 0.02) * exp(-max(0, t - 0.02) * 35)
                return hp.process(noise.next()) * env * 0.7
            }, sampleRate: sr)

        case .cowbell:
            var lp = LowPass(cutoff: 3_000, sampleRate: sr)
            var p1 = 0.0, p2 = 0.0
            return SampleBuffer(samples: render(0.3) { t, _ in
                p1 += 2 * .pi * 545 / sr
                p2 += 2 * .pi * 815 / sr
                let square = (sin(p1) > 0 ? 1.0 : -1.0) + (sin(p2) > 0 ? 1.0 : -1.0)
                return lp.process(square) * exp(-t * 11) * 0.35
            }, sampleRate: sr)

        case .conga:
            return SampleBuffer(samples: render(0.35) { t, phase in
                let f = 200 + 40 * exp(-t * 40)
                phase += 2 * .pi * f / sr
                return (sin(phase) + 0.25 * sin(2 * phase)) * exp(-t * 10) * 0.8
            }, sampleRate: sr)

        case .keys:
            // Soft electric-piano tone at C4.
            let f = midiToHz(60)
            return SampleBuffer(samples: render(1.1) { t, _ in
                let w = 2 * Double.pi * f * t
                let tone = sin(w) + 0.35 * sin(2 * w) * exp(-t * 6) + 0.12 * sin(3 * w) * exp(-t * 9)
                return tone * min(1, t / 0.004) * exp(-t * 3) * 0.55
            }, sampleRate: sr, baseNote: 60)

        case .pluck:
            return SampleBuffer(samples: karplusStrong(note: 60, duration: 0.9), sampleRate: sr, baseNote: 60)

        case .bell:
            let f = midiToHz(72)
            return SampleBuffer(samples: render(1.4) { t, _ in
                let mod = 2.2 * exp(-t * 4) * sin(2 * .pi * f * 3.5 * t)
                return sin(2 * .pi * f * t + mod) * exp(-t * 2.8) * min(1, t / 0.002) * 0.45
            }, sampleRate: sr, baseNote: 72)

        case .bass:
            let f = midiToHz(36)
            var lp = LowPass(cutoff: 700, sampleRate: sr)
            return SampleBuffer(samples: render(0.6) { t, _ in
                // Band-limited-ish saw from a few harmonics, then filtered.
                var saw = 0.0
                for h in 1...6 { saw += sin(2 * .pi * f * Double(h) * t) / Double(h) }
                return lp.process(saw) * min(1, t / 0.005) * exp(-t * 4) * 0.7
            }, sampleRate: sr, baseNote: 36)
        }
    }

    private static func render(_ duration: Double, _ fn: (Double, inout Double) -> Double) -> [Float] {
        let n = Int(duration * sampleRate)
        var phase = 0.0
        var out = [Float](repeating: 0, count: n)
        let fade = Int(0.005 * sampleRate)
        for i in 0..<n {
            var v = fn(Double(i) / sampleRate, &phase)
            if i > n - fade { v *= Double(n - i) / Double(fade) }  // avoid end clicks
            out[i] = Float(max(-1, min(1, v)))
        }
        return out
    }

    private static func karplusStrong(note: Double, duration: Double) -> [Float] {
        let period = Int(sampleRate / midiToHz(note))
        var noise = NoiseGenerator()
        var ring = (0..<period).map { _ in noise.next() }
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var idx = 0
        for i in 0..<n {
            let next = (idx + 1) % period
            let v = 0.5 * (ring[idx] + ring[next]) * 0.996
            out[i] = Float(ring[idx] * 0.6)
            ring[idx] = v
            idx = next
        }
        return out
    }

    static func midiToHz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }
}

// MARK: - Tiny DSP helpers

private struct NoiseGenerator {
    private var state: UInt32 = 0x1234_5678
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Double(state) / Double(UInt32.max) * 2 - 1
    }
}

private struct LowPass {
    private let a: Double
    private var y = 0.0
    init(cutoff: Double, sampleRate: Double) { a = 1 - exp(-2 * .pi * cutoff / sampleRate) }
    mutating func process(_ x: Double) -> Double { y += a * (x - y); return y }
}

private struct HighPass {
    private var lp: LowPass
    init(cutoff: Double, sampleRate: Double) { lp = LowPass(cutoff: cutoff, sampleRate: sampleRate) }
    mutating func process(_ x: Double) -> Double { x - lp.process(x) }
}

private struct BandPass {
    private var hp: HighPass
    private var lp: LowPass
    init(center: Double, q: Double, sampleRate: Double) {
        hp = HighPass(cutoff: center / (1 + q), sampleRate: sampleRate)
        lp = LowPass(cutoff: center * (1 + q), sampleRate: sampleRate)
    }
    mutating func process(_ x: Double) -> Double { lp.process(hp.process(x)) }
}
