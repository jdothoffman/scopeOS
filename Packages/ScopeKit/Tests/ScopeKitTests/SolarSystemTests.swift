import Foundation
import Testing
@testable import ScopeKit

/// Checked against NASA JPL Horizons (geocentric apparent RA/Dec, 2026-10-10 00:00 UT).
@Suite("Moon and planets")
struct SolarSystemTests {
    static let date = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-10 00:00 UT

    /// Horizons, in degrees.
    static let horizons: [(Planet, Double, Double)] = [
        (.mercury, 218.296456104, -17.885009219),
        (.venus, 212.620800838, -21.187384694),
        (.mars, 129.556927083, 19.695299647),
        (.jupiter, 143.734493929, 15.039445245),
        (.saturn, 11.056982370, 1.805030452),
        (.uranus, 63.451390202, 21.041602693),
        (.neptune, 2.965444629, -0.262403563),
    ]

    @Test func theDateIsRight() {
        #expect(Astronomy.julianDate(Self.date) == 2_461_323.5)
    }

    @Test(arguments: horizons.indices)
    func planetsMatchHorizons(_ index: Int) {
        let (planet, ra, dec) = Self.horizons[index]
        let computed = SolarSystem.position(of: planet, at: Self.date)
        let error = Astronomy.separation(computed, Equatorial(raHours: ra / 15, decDegrees: dec))
        #expect(error < 0.1, "\(planet.name) off by \(error)°")
    }

    @Test func theMoonMatchesHorizons() {
        let (computed, earthRadii) = SolarSystem.moonPosition(at: Self.date)
        let error = Astronomy.separation(computed, Equatorial(raHours: 186.715330764 / 15, decDegrees: -6.472782054))
        #expect(error < 0.15, "off by \(error)°")
        #expect(abs(earthRadii * 6_378.14 - 0.00257470369654 * 149_597_870.7) < 1_000, "distance") // km
    }
}
