import XCTest
@testable import NESWallpaperCore

final class SharedFramesTests: XCTestCase {
    func testTileURLNamingRoundTrips() {
        let url = SharedFrames.tileURL(pid: 4242, counter: 7)
        XCTAssertEqual(url.lastPathComponent, "nes.4242.7.frame")
        XCTAssertEqual(SharedFrames.ownerPid(of: url.lastPathComponent), 4242)
    }

    func testOwnerPidRejectsForeignNames() {
        XCTAssertNil(SharedFrames.ownerPid(of: "manifest.json"))
        XCTAssertNil(SharedFrames.ownerPid(of: "nes.notapid.0.frame"))
        XCTAssertNil(SharedFrames.ownerPid(of: "nes.123.frame"))
        XCTAssertNil(SharedFrames.ownerPid(of: "nes.123.x.frame"))
        XCTAssertNil(SharedFrames.ownerPid(of: ".DS_Store"))
    }

    func testManifestRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest.\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = SharedFrames.Manifest(
            pid: 4242, columns: 3, rows: 2, tileWidth: 256, tileHeight: 240,
            heartbeatPort: 50000, tiles: ["/a.frame", "/b.frame"])
        try SharedFrames.write(manifest, to: url)
        XCTAssertEqual(SharedFrames.readManifest(from: url), manifest)
    }

    func testManifestReadRejectsMissingOrGarbage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest.\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(SharedFrames.readManifest(from: url))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(SharedFrames.readManifest(from: url))
    }

    /// End-to-end over real loopback UDP: a datagram to the advertised port
    /// flips saverActive, and it decays after maxAge with no further beats.
    func testHeartbeatListenerReceivesBeats() {
        guard let listener = HeartbeatListener(maxAge: 0.5) else {
            XCTFail("failed to bind listener"); return
        }
        XCTAssertNotEqual(listener.port, 0)
        XCTAssertFalse(listener.saverActive)

        let beaten = expectation(description: "beat received")
        listener.onBeat = { beaten.fulfill() }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = listener.port.bigEndian
        var payload: UInt8 = 1
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, &payload, 1, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 1)

        // onBeat is delivered on the main queue; waiting spins the run loop.
        wait(for: [beaten], timeout: 2)
        XCTAssertTrue(listener.saverActive)

        // Past maxAge without another beat: stale again.
        let decayed = expectation(description: "beat decayed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { decayed.fulfill() }
        wait(for: [decayed], timeout: 2)
        XCTAssertFalse(listener.saverActive)
    }
}
