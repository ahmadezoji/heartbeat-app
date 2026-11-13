import Foundation

/// What the analyzer heard in a recording.
struct SoundAnalysis {
    enum Kind { case rhythm, melody }

    struct Hit {
        /// Seconds from the start of the recording.
        let time: Double
        /// Detected MIDI note (fractional) for pitched hits.
        let midiNote: Double?
        /// RMS frequency of the attack in Hz: low = boomy (kick), high = hissy (hi-hat).
        let brightness: Double
    }

    let kind: Kind
    let hits: [Hit]
    /// The user's own first sound, trimmed and normalised, usable as a sample.
    let clip: SampleBuffer?
}

/// Offline analysis of a short mic recording: onset detection, pitch (YIN),
/// percussive/tonal classification. Pure functions — easy to unit test.
enum SoundAnalyzer {
    static func analyze(samples: [Float], sampleRate: Double) -> SoundAnalysis? {
        let onsets = detectOnsets(samples, sampleRate: sampleRate)
        guard !onsets.isEmpty else { return nil }

        var hits: [SoundAnalysis.Hit] = []
        var pitchedCount = 0
        for onset in onsets {
            // Pitched AND sustained → a note. Kicks/thumps are briefly pitched but decay fast.
            let note = isSustained(at: onset, in: samples, sampleRate: sampleRate)
                ? pitch(at: onset, in: samples, sampleRate: sampleRate) : nil
            if note != nil { pitchedCount += 1 }
            hits.append(.init(time: Double(onset) / sampleRate,
                              midiNote: note,
                              brightness: rmsFrequency(at: onset, in: samples, sampleRate: sampleRate)))
        }

        // Mostly sustained, stable pitch (whistle / hum) → melody, otherwise rhythm.
        let kind: SoundAnalysis.Kind = Double(pitchedCount) >= Double(hits.count) * 0.6 ? .melody : .rhythm
        if kind == .rhythm {
            hits = hits.map { .init(time: $0.time, midiNote: nil, brightness: $0.brightness) }
        }
        let clip = extractClip(from: samples, sampleRate: sampleRate, onsets: onsets,
                               baseNote: kind == .melody ? hits.first?.midiNote : nil,
                               maxLength: kind == .melody ? 1.0 : 0.45)
        return SoundAnalysis(kind: kind, hits: hits, clip: clip)
    }

    // MARK: - Onsets

    /// Sample indices where a new sound starts, from an RMS energy envelope with
    /// an adaptive threshold and hysteresis.
    static func detectOnsets(_ x: [Float], sampleRate: Double) -> [Int] {
        let hop = max(1, Int(sampleRate * 0.005))  // 5 ms frames
        let frameCount = x.count / hop
        guard frameCount > 4 else { return [] }

        var envelope = [Float](repeating: 0, count: frameCount)
        x.withUnsafeBufferPointer { p in
            for f in 0..<frameCount {
                var sum: Float = 0
                let start = f * hop
                for i in start..<min(start + hop * 2, x.count) { sum += p[i] * p[i] }
                envelope[f] = sqrt(sum / Float(hop * 2))
            }
        }

        let sorted = envelope.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count) * 0.2)]
        let peak = sorted.last ?? 0
        guard peak > 0.02 else { return [] }  // too quiet: nothing intentional
        let threshold = max(noiseFloor + (peak - noiseFloor) * 0.22, noiseFloor * 3, 0.015)
        let rearm = threshold * 0.5
        let minGapFrames = Int(0.09 / 0.005)  // 90 ms between hits

        var onsets: [Int] = []
        var armed = true
        var lastOnsetFrame = -minGapFrames
        for f in 1..<frameCount {
            if armed, envelope[f] >= threshold, f - lastOnsetFrame >= minGapFrames {
                // Back up to where the rise began, for tighter timing.
                var start = f
                while start > 0, envelope[start - 1] < envelope[start], envelope[start - 1] > noiseFloor * 1.5 {
                    start -= 1
                }
                onsets.append(start * hop)
                lastOnsetFrame = f
                armed = false
            } else if !armed, envelope[f] < rearm {
                armed = true
            }
        }
        return onsets
    }

    // MARK: - Pitch

    /// MIDI note of the sound starting at `onset`, or nil if it isn't clearly pitched.
    /// Checks two windows (early and later) and requires them to agree, which
    /// rejects claps/taps that only have a brief tonal ring.
    static func pitch(at onset: Int, in x: [Float], sampleRate: Double) -> Double? {
        let offsets = [0.03, 0.08]
        var notes: [Double] = []
        for offset in offsets {
            let start = onset + Int(offset * sampleRate)
            guard let f0 = yin(x, start: start, sampleRate: sampleRate) else { return nil }
            notes.append(69 + 12 * log2(f0 / 440))
        }
        guard let first = notes.first, let last = notes.last, abs(first - last) < 1 else { return nil }
        return (first + last) / 2
    }

    /// YIN fundamental-frequency estimate (70–3000 Hz) on a 2048-sample window
    /// at ~24 kHz. Returns nil if the signal isn't periodic enough.
    static func yin(_ x: [Float], start: Int, sampleRate: Double) -> Double? {
        let decimation = sampleRate >= 32_000 ? 2 : 1
        let sr = sampleRate / Double(decimation)
        let window = 1024
        let tauMax = min(Int(sr / 70), 400)
        let tauMin = max(2, Int(sr / 3_000))
        let needed = (window + tauMax + 1) * decimation
        guard start >= 0, start + needed <= x.count else { return nil }

        // Decimate with a 2-tap average (crude low-pass).
        var y = [Float](repeating: 0, count: window + tauMax + 1)
        for i in 0..<y.count {
            let j = start + i * decimation
            y[i] = decimation == 2 ? 0.5 * (x[j] + x[j + 1]) : x[j]
        }
        var energy: Float = 0
        for i in 0..<window { energy += y[i] * y[i] }
        guard energy / Float(window) > 1e-5 else { return nil }

        var d = [Float](repeating: 0, count: tauMax + 1)
        y.withUnsafeBufferPointer { p in
            for tau in 1...tauMax {
                var sum: Float = 0
                for j in 0..<window {
                    let diff = p[j] - p[j + tau]
                    sum += diff * diff
                }
                d[tau] = sum
            }
        }
        // Cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        let threshold: Float = 0.15
        var tau = tauMin
        while tau < tauMax, cmnd[tau] >= threshold { tau += 1 }
        guard tau < tauMax else { return nil }
        while tau + 1 < tauMax, cmnd[tau + 1] < cmnd[tau] { tau += 1 }

        // Parabolic interpolation for sub-sample accuracy.
        let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? Double(0.5 * (a - c) / denom) : 0
        return sr / (Double(tau) + shift)
    }

    // MARK: - Timbre

    /// "Average frequency" of the first 40 ms: sqrt(E[dx²] / E[x²]) · sr / 2π.
    /// Exact for a sine, and dominated by the loud part of the sound, so mic
    /// noise in quiet moments barely affects it (unlike zero-crossing counts).
    static func rmsFrequency(at onset: Int, in x: [Float], sampleRate: Double) -> Double {
        let end = min(x.count, onset + Int(sampleRate * 0.04))
        guard end - onset > 2 else { return 0 }
        var signal: Double = 0, slope: Double = 0
        for i in (onset + 1)..<end {
            let v = Double(x[i]), d = Double(x[i] - x[i - 1])
            signal += v * v
            slope += d * d
        }
        guard signal > 0 else { return 0 }
        return sqrt(slope / signal) * sampleRate / (2 * .pi)
    }

    /// True if the sound is still at least ~30% as loud 90 ms after it started
    /// (whistles, hums) rather than a quickly decaying hit (claps, taps, kicks).
    static func isSustained(at onset: Int, in x: [Float], sampleRate: Double) -> Bool {
        func rms(from start: Int, seconds: Double) -> Float {
            let end = min(x.count, start + Int(seconds * sampleRate))
            guard end > start else { return 0 }
            var sum: Float = 0
            for i in start..<end { sum += x[i] * x[i] }
            return sqrt(sum / Float(end - start))
        }
        let attack = rms(from: onset, seconds: 0.03)
        let later = rms(from: onset + Int(0.09 * sampleRate), seconds: 0.03)
        return attack > 0 && later >= attack * 0.3
    }

    // MARK: - Clip

    private static func extractClip(from x: [Float], sampleRate: Double, onsets: [Int],
                                    baseNote: Double?, maxLength: Double) -> SampleBuffer? {
        guard let onset = onsets.first else { return nil }
        let start = max(0, onset - Int(0.005 * sampleRate))
        var end = min(x.count, onset + Int(maxLength * sampleRate))
        if onsets.count > 1 { end = min(end, onsets[1]) }
        guard end - start > Int(0.02 * sampleRate) else { return nil }

        var clip = Array(x[start..<end])
        let peak = clip.map(abs).max() ?? 0
        guard peak > 0 else { return nil }
        let gain = 0.9 / peak
        let fadeIn = Int(0.003 * sampleRate), fadeOut = min(Int(0.03 * sampleRate), clip.count / 2)
        for i in clip.indices {
            var g = gain
            if i < fadeIn { g *= Float(i) / Float(fadeIn) }
            if i >= clip.count - fadeOut { g *= Float(clip.count - i) / Float(fadeOut) }
            clip[i] *= g
        }
        return SampleBuffer(samples: clip, sampleRate: sampleRate, baseNote: baseNote ?? 60)
    }
}

// MARK: - Turning an analysis into sequencer rows

/// A sound the user can pick for their recorded pattern.
struct SoundSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let symbol: String
    let sound: SampleBuffer
    let rates: [Float]
}

enum PatternBuilder {
    /// Maps each hit onto the 8-step grid (folding longer recordings into one bar).
    /// `stepPosition` converts a hit's recording time to a grid position in steps.
    static func steps(for hits: [SoundAnalysis.Hit],
                      stepPosition: (Double) -> Double) -> (steps: [Bool], notes: [Double?]) {
        var steps = Array(repeating: false, count: StepGrid.stepCount)
        var notes = [Double?](repeating: nil, count: StepGrid.stepCount)
        for hit in hits {
            let step = StepGrid.wrap(Int(stepPosition(hit.time).rounded()))
            if !steps[step] {
                steps[step] = true
                notes[step] = hit.midiNote
            }
        }
        return (steps, notes)
    }

    static func suggestions(for analysis: SoundAnalysis, notes: [Double?],
                            library: SoundLibrary = .shared) -> [SoundSuggestion] {
        var result: [SoundSuggestion] = []
        switch analysis.kind {
        case .rhythm:
            let brightness = analysis.hits.map(\.brightness).reduce(0, +) / Double(max(analysis.hits.count, 1))
            let ranked: [SoundID]
            let character: String
            switch brightness {
            case ..<700:
                ranked = [.kick, .conga, .snare, .clap]; character = "deep, boomy"
            case ..<7_000:  // tune on device: real claps ~3–6 kHz, mouth "ts" > 8 kHz
                ranked = [.clap, .snare, .conga, .cowbell]; character = "snappy"
            default:
                ranked = [.hihat, .shaker, .snare, .clap]; character = "bright, airy"
            }
            for (i, id) in ranked.enumerated() {
                result.append(.init(name: id.displayName,
                                    detail: i == 0 ? "Best match — sounds \(character)" : "Drum kit",
                                    symbol: id.symbol, sound: library.sound(id),
                                    rates: Array(repeating: 1, count: StepGrid.stepCount)))
            }
            if let clip = analysis.clip {
                result.append(.init(name: "My sound", detail: "Use your own recording",
                                    symbol: "mic.fill", sound: clip,
                                    rates: Array(repeating: 1, count: StepGrid.stepCount)))
            }

        case .melody:
            let played = notes.compactMap { $0 }
            let melodic: [(SoundID, String, Double)] = [
                (.keys, "Soft electric piano", 66), (.pluck, "Plucked string", 66),
                (.bell, "Glassy bell", 78), (.bass, "Deep bass", 42),
            ]
            for (id, detail, target) in melodic {
                let sound = library.sound(id)
                let shift = octaveShift(for: played, toward: target)
                result.append(.init(name: id.displayName, detail: detail, symbol: id.symbol, sound: sound,
                                    rates: notes.map { $0.map { sound.rate(forNote: $0.rounded() + shift) } ?? 1 }))
            }
            if let clip = analysis.clip {
                result.append(.init(name: "My sound", detail: "Your own voice/whistle, re-pitched",
                                    symbol: "mic.fill", sound: clip,
                                    rates: notes.map { $0.map { clip.rate(forNote: $0.rounded()) } ?? 1 }))
            }
        }
        return result
    }

    /// Whole octaves that move the melody's median note near `target`, so a high
    /// whistle still plays in a comfortable range for each instrument.
    static func octaveShift(for notes: [Double], toward target: Double) -> Double {
        guard !notes.isEmpty else { return 0 }
        let median = notes.sorted()[notes.count / 2]
        return ((target - median) / 12).rounded() * 12
    }

    static func noteName(_ midi: Double) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let n = Int(midi.rounded())
        return names[((n % 12) + 12) % 12] + String(n / 12 - 1)
    }
}
