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
}
