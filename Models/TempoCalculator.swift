import Foundation

enum TempoCalculator {
    static let defaultTempo: Double = 72
    static let defaultSpeedFactor: Double = 4
    private static let minTempo: Double = 40
    private static let maxTempo: Double = 200

    static func calculateTempo(baseTempo: Double, speedMetersPerSecond: Double, speedFactor: Double) -> Double {
        let newTempo = baseTempo + (speedMetersPerSecond * speedFactor)
        return min(max(newTempo, minTempo), maxTempo)
    }

    static func rate(for tempo: Double, baseTempo: Double) -> Double {
        guard baseTempo > 0 else { return 1 }
        let rate = tempo / baseTempo
        return min(max(rate, 0.5), 2.0)
    }
}
