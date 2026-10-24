import CoreLocation
import Foundation
import MacToysCore

/// A one-shot "where am I" request for sunrise and sunset, with the permission prompt when needed.
@MainActor
final class LocationRequest: NSObject, CLLocationManagerDelegate {
    enum Failure: Error, LocalizedError {
        case denied, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .denied:
                "Location access is off for MacToys. Allow it in System Settings › Privacy & Security › Location Services, or enter coordinates."
            case .unavailable(let message): "Couldn't find your location: \(message)"
            }
        }
    }

    private let manager = CLLocationManager()
    private var completion: ((Result<CLLocationCoordinate2D, Failure>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start(_ completion: @escaping (Result<CLLocationCoordinate2D, Failure>) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.failure(.denied))
        default: manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) {
        let c = completion
        completion = nil
        c?(result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(.denied))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        MainActor.assumeIsolated { finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(.failure(denied ? .denied : .unavailable(message))) }
    }
}
