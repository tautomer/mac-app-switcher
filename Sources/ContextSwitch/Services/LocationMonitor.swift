import Foundation
import CoreLocation
import Combine

/// Location permission + the optional location signal. Wi-Fi names need
/// the permission too: macOS redacts SSIDs for apps without it.
///
/// Uses region monitoring (geofences) plus one-shot fixes rather than
/// continuous tracking — cheap on battery, and only wakes us when we cross
/// into/out of a saved place.
final class LocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var onLocationUpdate: ((SimpleLocation?) -> Void)?

    private let manager = CLLocationManager()
    private var pendingRegions: [CLCircularRegion]?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    /// macOS has a single granted state.
    var isAuthorized: Bool { authorizationStatus == .authorizedAlways }

    var isDenied: Bool { authorizationStatus == .denied || authorizationStatus == .restricted }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot fix, e.g. for "Use Current Location". Asks for permission
    /// first if needed; the fix is delivered through `onLocationUpdate`.
    func requestCurrentLocation() {
        if isAuthorized {
            manager.requestLocation()
        } else {
            requestPermission()
        }
    }

    /// Replaces the monitored geofences. Pass an empty array to stop.
    func monitor(regions: [(name: String, latitude: Double, longitude: Double, radius: Double)]) {
        let circular = regions.map { r in
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                radius: min(r.radius, manager.maximumRegionMonitoringDistance),
                identifier: "\(r.name)|\(r.latitude)|\(r.longitude)|\(r.radius)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            return region
        }
        guard isAuthorized || circular.isEmpty else {
            pendingRegions = circular
            requestPermission()
            return
        }
        apply(circular)
    }

    private func apply(_ regions: [CLCircularRegion]) {
        let wanted = Set(regions.map(\.identifier))
        for region in manager.monitoredRegions where !wanted.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for region in regions where !existing.contains(region.identifier) {
            manager.startMonitoring(for: region)
        }
        if !regions.isEmpty {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized, let pending = pendingRegions {
            pendingRegions = nil
            apply(pending)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        onLocationUpdate?(SimpleLocation(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (e.g. no fix yet); the next region event retries.
        ActivityLog.shared.debug("Location: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        manager.requestLocation()
    }
}
