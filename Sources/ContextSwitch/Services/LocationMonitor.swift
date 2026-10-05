import Foundation
import CoreLocation
import Combine

/// Optional location signal. Uses region monitoring (geofences) rather than
/// continuous GPS tracking — cheap on battery, and only wakes us up when we
/// cross into/out of a saved place. Entirely opt-in: profiles that don't
/// use a `.location` condition never trigger an authorization prompt.
final class LocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: SimpleLocation?

    var onLocationUpdate: ((SimpleLocation?) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Call once there's at least one profile with a `.location` condition.
    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways:
            return true
        default:
            return false
        }
    }

    func startMonitoring(regions: [(name: String, latitude: Double, longitude: Double, radius: Double)]) {
        guard isAuthorized else {
            requestPermission()
            return
        }
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        for r in regions {
            let center = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
            let region = CLCircularRegion(center: center, radius: r.radius, identifier: r.name)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        manager.startUpdatingLocation()
    }

    func stopMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let simple = SimpleLocation(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        lastLocation = simple
        onLocationUpdate?(simple)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        manager.requestLocation()
    }
}
