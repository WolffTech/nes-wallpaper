// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import nes_wallpaper

final class PlaybackDemandTests: XCTestCase {
    func testPlaybackStopsWithoutDesktopOrSaverDemand() {
        let demand = PlaybackDemand(desktop: false, saver: false)

        XCTAssertFalse(demand.needsPlayback)
    }

    func testDesktopDemandStartsPlayback() {
        let demand = PlaybackDemand(desktop: true, saver: false)

        XCTAssertTrue(demand.needsPlayback)
    }

    func testSaverDemandStartsPlaybackWithoutDesktopPresentation() {
        let demand = PlaybackDemand(desktop: false, saver: true)

        XCTAssertTrue(demand.needsPlayback)
        XCTAssertFalse(demand.desktop)
    }

    func testPlaybackContinuesUntilBothDemandsEnd() {
        var demand = PlaybackDemand(desktop: true, saver: true)

        demand.desktop = false
        XCTAssertTrue(demand.needsPlayback)

        demand.saver = false
        XCTAssertFalse(demand.needsPlayback)
    }
}
