import Foundation

/// Single source of truth for the app's tempo, shared by every tab.
///
/// Tempo = base tempo (set by the runner) + running speed × speed influence.
/// The Home player and the Compose step sequencer both follow `currentTempo`.
final class TempoController: ObservableObject {
    @Published var baseTempo: Double { didSet { recalculate() } }
    @Published var speedFactor: Double { didSet { recalculate() } }
    @Published private(set) var speedMetersPerSecond: Double = 0
    @Published private(set) var currentTempo: Double

    static let tempoRange: ClosedRange<Double> = 40...200

    init(baseTempo: Double = AudioEngineManager.defaultTrackBPM,
         speedFactor: Double = TempoCalculator.defaultSpeedFactor) {
        self.baseTempo = baseTempo
        self.speedFactor = speedFactor
        self.currentTempo = baseTempo
        recalculate()
    }

    func updateSpeed(_ metersPerSecond: Double) {
        speedMetersPerSecond = metersPerSecond
        recalculate()
    }

    func nudgeBaseTempo(by delta: Double) {
        baseTempo = min(max(baseTempo + delta, Self.tempoRange.lowerBound), Self.tempoRange.upperBound)
    }

    private func recalculate() {
        let tempo = TempoCalculator.calculateTempo(
            baseTempo: baseTempo,
            speedMetersPerSecond: speedMetersPerSecond,
            speedFactor: speedFactor
        )
        if tempo != currentTempo { currentTempo = tempo }
    }
}
