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
            pid: 4242, columns: 3, rows: 2,
            tiles: ["/a.frame", "/b.frame"])
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

    func testHeartbeatFreshness() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat.\(getpid())")
        defer { try? FileManager.default.removeItem(at: url) }

        // Missing file: not fresh.
        XCTAssertFalse(SharedFrames.heartbeatFresh(at: url))

        try Data().write(to: url)
        XCTAssertTrue(SharedFrames.heartbeatFresh(at: url))
        // Same mtime, judged from 10s in the future: stale.
        XCTAssertFalse(SharedFrames.heartbeatFresh(
            at: url, now: Date(timeIntervalSinceNow: 10)))
        // An mtime in the future (clock skew) is stale, not ultra-fresh.
        XCTAssertFalse(SharedFrames.heartbeatFresh(
            at: url, now: Date(timeIntervalSinceNow: -10)))
    }

    func testHeartbeatURLIsInsideGivenHome() {
        let url = SharedFrames.heartbeatURL(home: URL(fileURLWithPath: "/container"))
        XCTAssertEqual(
            url.path,
            "/container/Library/Application Support/NESWallpaper/heartbeat")
    }
}
