import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Telescope finder", .serialized)
struct TelescopeFinderTests {
    @Test func onlyWiFiAndEthernetAreScanned() {
        for name in ["en0", "en1", "en7"] { #expect(TelescopeFinder.isScannable(interface: name), "\(name)") }
        for name in ["utun3", "ipsec0", "ppp0", "bridge100", "vmnet8", "vnic0", "awdl0", "llw0", "anpi1", "lo0", "gif0", "stf0"] {
            #expect(!TelescopeFinder.isScannable(interface: name), "\(name)")
        }
    }

    @Test func cancellingAFindStopsItQuickly() async {
        // Unroutable test addresses: every probe would wait out its whole timeout.
        let hosts = (1 ... 200).map { "192.0.2.\($0)" }
        let started = ContinuousClock.now
        let search = Task { await TelescopeFinder.find(hosts: hosts, concurrency: 4, connectTimeout: .milliseconds(300)) }
        try? await Task.sleep(for: .milliseconds(100))
        search.cancel()
        _ = await search.value
        #expect(ContinuousClock.now - started < .seconds(2), "200 hosts, 4 at a time, would take 15 s")
    }
    @Test func listsTheHostsOfASubnet() {
        let home = TelescopeFinder.hosts(address: 0xC0A8_00BB, mask: 0xFFFF_FF00) // 192.168.0.187/24
        #expect(home.count == 254)
        #expect(home.first == "192.168.0.1")
        #expect(home.last == "192.168.0.254")
        // A /16 is narrowed to the /24 around the Mac, so a scan stays small.
        let wide = TelescopeFinder.hosts(address: 0x0A01_0205, mask: 0xFFFF_0000) // 10.1.2.5/16
        #expect(wide.count == 254 && wide.first == "10.1.2.1")
        // The module's own network.
        #expect(TelescopeFinder.hosts(address: 0x0102_0305, mask: 0xFFFF_FF00).contains("1.2.3.4"))
    }

    @Test func findsAnAuxBusAndIgnoresOtherServices() async throws {
        let aux = try SimulatorServer(flavor: .aux, port: 0)
        try await aux.start()
        defer { aux.stop() }
        let port = try #require(aux.port)

        let found = await TelescopeFinder.find(hosts: ["127.0.0.1", "127.0.0.2"], port: port)
        #expect(found == [TelescopeFinder.Found(host: "127.0.0.1", port: port)])
    }

    @Test func doesNotMistakeAHandControllerServerForTheWiFiModule() async throws {
        let handController = try SimulatorServer(flavor: .handController, port: 0)
        try await handController.start()
        defer { handController.stop() }
        let found = await TelescopeFinder.find(hosts: ["127.0.0.1"], port: try #require(handController.port))
        #expect(found.isEmpty)
    }

    @Test func findsNothingWhereNothingListens() async {
        let start = ContinuousClock.now
        let found = await TelescopeFinder.find(hosts: (1 ... 20).map { "127.0.0.\($0)" }, port: 1)
        #expect(found.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
