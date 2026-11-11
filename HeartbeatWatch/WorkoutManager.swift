import CoreLocation
import HealthKit
import SwiftUI

/// Runs an outdoor-running HKWorkoutSession so the app keeps running (audio,
/// GPS, haptics) while the wrist is down, and publishes speed + heart rate.
final class WorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var speedMetersPerSecond: Double = 0
    @Published private(set) var heartRate: Double = 0
    @Published private(set) var statusText = "Tap Start to run."

    var speedKilometersPerHour: Double { speedMetersPerSecond * 3.6 }

    /// Called on every GPS speed update, including while the wrist is down.
    /// Wired directly to the audio so tempo keeps adapting with the screen off
    /// (SwiftUI `onChange` is not guaranteed to fire in the background).
    var onSpeedChange: ((Double) -> Void)?

    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        // Requires the "location" UIBackgroundModes entry in Info.plist.
        locationManager.allowsBackgroundLocationUpdates = true
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()

        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(hr) }
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async { self?.statusText = "Health: \(error.localizedDescription)" }
            }
        }
    }

    func start() {
        guard !isActive else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
        } catch {
            // Without a workout session the app still works in the foreground.
            statusText = "Workout unavailable: \(error.localizedDescription)"
        }

        locationManager.startUpdatingLocation()
        isActive = true
        statusText = "Running."
    }

    func stop() {
        guard isActive else { return }
        locationManager.stopUpdatingLocation()
        session?.end()
        if let builder = builder {
            builder.endCollection(withEnd: Date()) { _, _ in
                builder.finishWorkout { _, _ in }
            }
        }
        session = nil
        builder = nil
        isActive = false
        speedMetersPerSecond = 0
        onSpeedChange?(0)
        statusText = "Run saved."
    }
}

extension WorkoutManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // CLLocation.speed is -1 when invalid.
        speedMetersPerSecond = max(0, location.speed)
        onSpeedChange?(speedMetersPerSecond)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "GPS: \(error.localizedDescription)"
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.statusText = "Workout: \(error.localizedDescription)" }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let value = stats.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        else { return }
        DispatchQueue.main.async { self.heartRate = value }
    }
}
