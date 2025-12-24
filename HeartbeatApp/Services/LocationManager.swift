import CoreLocation
import SwiftUI

final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var speedMetersPerSecond: Double = 0
    @Published private(set) var statusText: String = "Location inactive."

    private let manager = CLLocationManager()

    var speedKilometersPerHour: Double {
        speedMetersPerSecond * 3.6
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startTracking() {
        manager.startUpdatingLocation()
        statusText = "Tracking enabled."
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        statusText = "Tracking stopped."
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            statusText = "Location authorized."
        case .denied, .restricted:
            statusText = "Location access denied."
        case .notDetermined:
            statusText = "Awaiting location permission."
        @unknown default:
            statusText = "Unknown authorization status."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let speed = max(0, location.speed)
        speedMetersPerSecond = speed
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "Location error: \(error.localizedDescription)"
    }
}
