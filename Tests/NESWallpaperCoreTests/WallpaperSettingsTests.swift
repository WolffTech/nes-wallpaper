// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import nes_wallpaper

final class WallpaperSettingsTests: XCTestCase {
    func testDockIconIsHiddenByDefault() {
        withDefaults { defaults in
            XCTAssertFalse(WallpaperSettings.load(defaults: defaults).showDockIcon)
        }
    }

    func testDockIconPreferenceRoundTrips() {
        withDefaults { defaults in
            var settings = WallpaperSettings.load(defaults: defaults)
            settings.showDockIcon = true
            settings.save(defaults: defaults)

            XCTAssertTrue(WallpaperSettings.load(defaults: defaults).showDockIcon)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "WallpaperSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
