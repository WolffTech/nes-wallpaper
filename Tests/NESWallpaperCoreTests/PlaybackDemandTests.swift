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

    func testStoppingPausedWallpaperThenStartingSaverResetsPause() {
        var demand = PlaybackDemand(desktop: true, saver: false)
        demand.userPaused = true

        demand.desktop = false
        XCTAssertFalse(demand.needsPlayback)
        XCTAssertFalse(demand.userPaused)

        demand.saver = true
        XCTAssertTrue(demand.needsPlayback)
        XCTAssertFalse(demand.userPaused)
    }

    func testStoppingPausedWallpaperWhileSaverIsActiveResetsPause() {
        var demand = PlaybackDemand(desktop: true, saver: true)
        demand.userPaused = true

        demand.desktop = false

        XCTAssertTrue(demand.needsPlayback)
        XCTAssertFalse(demand.userPaused)
    }

    func testRestartingWallpaperAfterStopResetsPause() {
        var demand = PlaybackDemand()
        demand.userPaused = true

        demand.desktop = false
        demand.desktop = true

        XCTAssertTrue(demand.needsPlayback)
        XCTAssertFalse(demand.userPaused)
    }

    func testPauseSurvivesSaverActivityAndReapplyingDesktopSettings() {
        var demand = PlaybackDemand()
        demand.userPaused = true

        demand.saver = true
        XCTAssertTrue(demand.userPaused)
        demand.saver = false
        XCTAssertTrue(demand.userPaused)
        demand.desktop = true
        XCTAssertTrue(demand.userPaused)
    }
}
