import CoreGraphics
import Foundation
import Testing
@testable import ScopeKit

@Suite("Sky map")
struct SkyMapTests {
    let observer = Observer(latitude: 38.89, longitude: -77.04)
    let date = Date(timeIntervalSince1970: 1_791_590_400)

    @Test func theCatalogueLoads() throws {
        let stars = SkyCatalog.stars
        #expect(stars.count > 8_000)
        #expect(zip(stars, stars.dropFirst()).allSatisfy { $0.magnitude <= $1.magnitude }, "brightest first")
        let vega = try #require(stars.first { $0.name == "Vega" })
        #expect(vega.designation == "α Lyr" && abs(vega.magnitude - 0.03) < 0.01)
        #expect(stars.first { $0.hr == 3 }?.label == "33 Psc", "falls back to the designation")
        #expect(SkyCatalog.constellations.count == 88)
        #expect(SkyCatalog.constellations.first { $0.id == "UMa" }?.name == "Ursa Major")
        #expect(SkyCatalog.constellations.allSatisfy { !$0.lines.isEmpty })
    }

    @Test(arguments: [(10.0, 20.0), (180, 45), (300, 5), (45, 80)])
    func horizontalAndEquatorialRoundTrip(_ azimuth: Double, _ altitude: Double) {
        let sky = Horizontal(azimuth: azimuth, altitude: altitude)
        let back = Astronomy.horizontal(Astronomy.equatorial(from: sky, at: date, observer: observer), at: date, observer: observer)
        #expect(Astronomy.separation(sky, back) < 1e-6)
    }

    @Test func theProjectionLooksOutAlongTheCentre() throws {
        let projection = SkyProjection(center: Horizontal(azimuth: 180, altitude: 0), fieldRadius: 30,
                                       origin: CGPoint(x: 400, y: 300), radius: 250)
        let centre = try #require(projection.point(for: projection.center))
        #expect(abs(centre.x - 400) < 1e-9 && abs(centre.y - 300) < 1e-9)
        let right = try #require(projection.point(for: Horizontal(azimuth: 210, altitude: 0)))
        #expect(abs(right.x - 650) < 1e-6 && abs(right.y - 300) < 1e-6, "30° further round is the edge, to the right")
        let up = try #require(projection.point(for: Horizontal(azimuth: 180, altitude: 10)))
        #expect(up.y < 300, "higher is up")
        #expect(projection.point(for: Horizontal(azimuth: 0, altitude: 0)) == nil, "behind the viewer")
        for point in [CGPoint(x: 100, y: 120), CGPoint(x: 640, y: 480), CGPoint(x: 410, y: 290)] {
            let back = try #require(projection.point(for: projection.sky(at: point)))
            #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
        }
    }

    @Test func theMoonSitsLowerThanSeenFromTheEarthsCentre() {
        let (position, _) = SolarSystem.moonPosition(at: date)
        let geocentric = Astronomy.horizontal(position, at: date, observer: observer)
        let topocentric = SkyTarget.moon.horizontal(at: date, observer: observer)
        let drop = geocentric.altitude - topocentric.altitude
        #expect(drop > 0 && drop < 1.0, "parallax \(drop)°")
        #expect(abs(geocentric.azimuth - topocentric.azimuth) < 1e-9)
    }
}
