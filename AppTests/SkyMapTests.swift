import CoreGraphics
import Foundation
import ScopeKit
import Testing

@MainActor
@Suite("Sky map clicks")
struct SkyMapClickTests {
    let observer = Observer(latitude: 38.89, longitude: -77.04)
    /// 2026-10-10 02:00 UT: Vega is well up in the west.
    let date = Date(timeIntervalSince1970: 1_791_597_600)

    private func renderer(centeredOn sky: Horizontal) -> SkyMapRenderer {
        SkyMapRenderer(projection: SkyProjection(center: sky, fieldRadius: 20, origin: CGPoint(x: 400, y: 300), radius: 300),
                       date: date, observer: observer, telescope: nil, selection: nil)
    }

    @Test func clickingAStarSelectsIt() throws {
        let vega = try #require(SkyMapData.stars.first { $0.star.name == "Vega" })
        let sky = Astronomy.horizontal(vega.position, at: date, observer: observer)
        #expect(sky.altitude > 20)
        let hit = renderer(centeredOn: sky).hitTest(CGPoint(x: 403, y: 298))
        #expect(hit == .star(hr: 7001))
        #expect(hit.target?.name == "Vega")
    }

    @Test func clickingEmptySkySelectsThatSpot() throws {
        let renderer = renderer(centeredOn: Horizontal(azimuth: 20, altitude: 50))
        // The first point on a coarse grid with nothing within reach: that click must select the spot itself.
        let grid = stride(from: 100.0, to: 700, by: 37).flatMap { x in stride(from: 80.0, to: 520, by: 41).map { CGPoint(x: x, y: $0) } }
        let empty = try #require(grid.first { if case .spot = renderer.hitTest($0) { true } else { false } })
        let hit = renderer.hitTest(empty)
        let target = try #require(hit.target)
        #expect(Astronomy.separation(target.horizontal(at: date, observer: observer), renderer.projection.sky(at: empty)) < 0.01,
                "Go to would aim where the click was")
    }
}
