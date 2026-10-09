import Foundation
import Testing
@testable import ScopeKit

@Suite("Star positions")
struct SkyTargetTests {
    private static func date(julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400) }

    /// Meeus, Astronomical Algorithms, example 21.b: θ Persei to 2028 Nov 13.19. Its proper motion is folded into
    /// the starting position, since `precess` leaves proper motion out.
    @Test func precessionMatchesMeeus() {
        let start = Equatorial(raHours: 2 + 44.0 / 60 + (11.986 + 0.988) / 3600, decDegrees: 49 + 13.0 / 60 + (42.48 - 2.58) / 3600)
        let result = Astronomy.precess(start, to: Self.date(julian: 2_462_088.69))
        #expect(abs(result.raHours - (2 + 46.0 / 60 + 11.331 / 3600)) * 3600 < 0.02) // seconds of time
        #expect(abs(result.decDegrees - (49 + 20.0 / 60 + 54.54 / 3600)) * 3600 < 0.3) // arcseconds
    }

    @Test func polarisIsAboutTwoThirdsOfADegreeFromThePoleIn2026() {
        let polaris = SkyTarget.polaris.position(at: Self.date(julian: 2_461_041.5)) // 2026 Jan 1
        #expect(abs((90 - polaris.decDegrees) - 0.62) < 0.02)
    }

    @Test func theCatalogueIsSane() throws {
        #expect(SkyTarget.brightStars.first == SkyTarget.polaris)
        #expect(Set(SkyTarget.brightStars.map(\.name)).count == SkyTarget.brightStars.count)
        for star in SkyTarget.brightStars {
            let position = try #require(star.j2000, "\(star.name)")
            #expect((0 ..< 24).contains(position.raHours), "\(star.name)")
            #expect((-90 ... 90).contains(position.decDegrees), "\(star.name)")
        }
        let vega = SkyTarget.brightStars.first { $0.name == "Vega" }
        #expect(abs((vega?.j2000?.decDegrees ?? 0) - 38.7837) < 0.001)
    }
}
