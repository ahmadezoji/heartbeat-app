import SwiftUI

/// Which section of the Compose grid a row belongs to.
enum Instrument: String, CaseIterable, Identifiable {
    case drums, synth
    var id: String { rawValue }
    var displayName: String { self == .drums ? "Drums" : "Synth" }
    var symbol: String { self == .drums ? "circle.grid.cross.fill" : "pianokeys" }
}

enum RowGroup: Equatable {
    case instrument(Instrument)
    case recorded
}

/// One row of the step grid: a sound plus which of the steps trigger it.
struct SequencerRow: Identifiable {
    let id = UUID()
    var name: String
    var symbol: String
    var color: Color
    var group: RowGroup
    var sound: SampleBuffer
    var steps: [Bool]
    /// Playback rate per step (1 = original pitch). Lets one sample play a melody.
    var rates: [Float]
    var volume: Float = 1

    init(name: String, symbol: String, color: Color, group: RowGroup, sound: SampleBuffer,
         steps: [Bool]? = nil, rates: [Float]? = nil, volume: Float = 1) {
        self.name = name
        self.symbol = symbol
        self.color = color
        self.group = group
        self.sound = sound
        self.steps = steps ?? Array(repeating: false, count: StepGrid.stepCount)
        self.rates = rates ?? Array(repeating: 1, count: StepGrid.stepCount)
        self.volume = volume
    }
}

enum StepGrid {
    /// 8 steps per row = one 4/4 bar of eighth notes.
    static let stepCount = 8
    /// Steps per beat (quarter note). 2 → eighth-note steps.
    static let stepsPerBeat = 2.0

    static func stepDuration(bpm: Double) -> Double { 60 / max(bpm, 1) / stepsPerBeat }

    /// Wraps an absolute step index into 0..<stepCount (handles negatives).
    static func wrap(_ step: Int) -> Int {
        ((step % stepCount) + stepCount) % stepCount
    }
}

// MARK: - Default content

enum DefaultKits {
    static let drumColors: [SoundID: Color] = [
        .kick: Color(red: 0.86, green: 0.22, blue: 0.78),
        .snare: Color(red: 0.88, green: 0.64, blue: 0.20),
        .clap: Color(red: 0.95, green: 0.52, blue: 0.25),
        .hihat: Color(red: 0.38, green: 0.80, blue: 0.82),
        .shaker: Color(red: 0.30, green: 0.66, blue: 0.95),
        .cowbell: Color(red: 0.58, green: 0.38, blue: 0.98),
        .conga: Color(red: 0.42, green: 0.82, blue: 0.30),
    ]

    /// A simple house groove so pressing Play does something right away:
    /// four-on-the-floor kick, off-beat hats, clap on 2 and 4.
    static func drumRows(_ lib: SoundLibrary = .shared) -> [SequencerRow] {
        let pattern: [SoundID: [Int]] = [
            .kick: [0, 2, 4, 6],
            .clap: [2, 6],
            .hihat: [1, 3, 5, 7],
        ]
        let ids: [SoundID] = [.kick, .snare, .clap, .hihat, .shaker, .cowbell, .conga]
        return ids.map { id in
            var steps = Array(repeating: false, count: StepGrid.stepCount)
            pattern[id]?.forEach { steps[$0] = true }
            return SequencerRow(name: id.displayName, symbol: id.symbol,
                                color: drumColors[id] ?? .gray,
                                group: .instrument(.drums), sound: lib.sound(id), steps: steps)
        }
    }

    /// C minor pentatonic, highest note on top — any combination sounds good.
    static let synthNotes: [(name: String, midi: Double)] = [
        ("C5", 72), ("A#4", 70), ("G4", 67), ("F4", 65), ("D#4", 63), ("C4", 60),
    ]

    static func synthRows(_ lib: SoundLibrary = .shared) -> [SequencerRow] {
        let keys = lib.sound(.keys)
        return synthNotes.enumerated().map { index, note in
            let hue = 0.72 - Double(index) * 0.06
            return SequencerRow(name: note.name, symbol: "pianokeys",
                                color: Color(hue: hue, saturation: 0.6, brightness: 0.95),
                                group: .instrument(.synth), sound: keys,
                                rates: Array(repeating: keys.rate(forNote: note.midi), count: StepGrid.stepCount),
                                volume: 0.8)
        }
    }
}
