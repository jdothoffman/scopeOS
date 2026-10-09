import CoreLocation
import Foundation
import Observation
import ScopeKit

/// Where the observer is: from Location Services (WiFi-based on a Mac) or typed in. The last position is saved,
/// because Location Services needs internet, and there is none while the Mac is on the telescope's WiFi.
@MainActor
@Observable
final class LocationModel: NSObject, CLLocationManagerDelegate {
    enum Source: String, Codable {
        case locationServices, manual

        var label: String {
            switch self {
            case .locationServices: "Location Services"
            case .manual: "Entered manually"
            }
        }
    }

    private struct Saved: Codable {
        var observer: Observer
        var source: Source
        var date: Date
    }

    private(set) var observer: Observer?
    private(set) var source: Source?
    private(set) var fixDate: Date?
    private(set) var locating = false
    private(set) var problem: String?
    var manualLatitude = ""
    var manualLongitude = ""

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let defaults: UserDefaults
    private static let savedKey = "observer"

    /// `defaults` is where the last position is kept (tests use their own).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: Self.savedKey), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            observer = saved.observer
            source = saved.source
            fixDate = saved.date
            manualLatitude = String(format: "%.4f", saved.observer.latitude)
            manualLongitude = String(format: "%.4f", saved.observer.longitude)
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func locate() {
        problem = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            locating = true
            manager.requestWhenInUseAuthorization() // continues in locationManagerDidChangeAuthorization
        case .denied, .restricted:
            problem = Self.deniedMessage
        default:
            locating = true
            manager.requestLocation()
        }
    }

    func applyManual() {
        let parse = { (text: String) in Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        guard let latitude = parse(manualLatitude), let longitude = parse(manualLongitude),
              Observer(latitude: latitude, longitude: longitude).isValid
        else {
            problem = "Enter latitude between −90 and 90 and longitude between −180 and 180, in decimal degrees (west and south are negative)."
            return
        }
        problem = nil
        save(Observer(latitude: latitude, longitude: longitude), source: .manual, date: .now)
    }

    private func save(_ observer: Observer, source: Source, date: Date) {
        self.observer = observer
        self.source = source
        fixDate = date
        manualLatitude = String(format: "%.4f", observer.latitude)
        manualLongitude = String(format: "%.4f", observer.longitude)
        if let data = try? JSONEncoder().encode(Saved(observer: observer, source: source, date: date)) {
            defaults.set(data, forKey: Self.savedKey)
        }
    }

    private static let deniedMessage = "Location access is off for scopeOS. Turn it on in System Settings › Privacy & Security › Location Services, or enter your position below."

    // MARK: CLLocationManagerDelegate (called on the main thread, since the manager was created there)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.locating else { return }
            switch status {
            case .notDetermined:
                break
            case .denied, .restricted:
                self.locating = false
                self.problem = Self.deniedMessage
            default:
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let observer = Observer(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let date = location.timestamp
        Task { @MainActor in
            self.locating = false
            self.save(observer, source: .locationServices, date: date)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let message = error.localizedDescription
        Task { @MainActor in
            self.locating = false
            switch code {
            case .denied: self.problem = Self.deniedMessage
            case .locationUnknown: self.problem = "Couldn't find your position. Location Services needs an internet connection; the last saved position stays in use."
            default: self.problem = "Couldn't find your position: \(message)"
            }
        }
    }
}

/// The Sun as seen from the observer, and how far the telescope is pointing from it.
struct SunSituation {
    let position: Horizontal
    let darkness: SkyDarkness
    let siderealHours: Double

    init(observer: Observer, date: Date) {
        position = Astronomy.horizontal(Astronomy.sunPosition(at: date), at: date, observer: observer)
        darkness = SkyDarkness(sunAltitude: position.altitude)
        siderealHours = Astronomy.localSiderealHours(at: date, longitude: observer.longitude)
    }

    /// Angle from the telescope to the Sun. Exact from RA/Dec (hand controller); approximate from the motor
    /// angles (WiFi module), which match the sky only as well as the mount's alignment.
    static func distance(status: MountStatus?, observer: Observer?, date: Date) -> (degrees: Double, approximate: Bool)? {
        if let equatorial = status?.equatorial {
            return (Astronomy.separation(equatorial, Astronomy.sunPosition(at: date)), false)
        }
        if let pointing = status?.horizontal, let observer {
            return (Astronomy.separation(pointing, SunSituation(observer: observer, date: date).position), true)
        }
        return nil
    }
}
