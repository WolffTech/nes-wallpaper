// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import nes_wallpaper

final class WallpaperSettingsTests: XCTestCase {
    func testTakeoverShortcutHasDefault() {
        withDefaults { defaults in
            XCTAssertEqual(WallpaperSettings.load(defaults: defaults).takeoverShortcut,
                           .defaultTakeover)
        }
    }

    func testTakeoverShortcutRoundTrips() throws {
        try withDefaults { defaults in
            let shortcut = try XCTUnwrap(GlobalShortcut(
                keyCode: 11, modifiers: [.command, .shift]))
            var settings = WallpaperSettings.load(defaults: defaults)
            settings.takeoverShortcut = shortcut
            settings.save(defaults: defaults)

            XCTAssertEqual(WallpaperSettings.load(defaults: defaults).takeoverShortcut,
                           shortcut)
        }
    }

    func testTakeoverShortcutCanBeDisabled() {
        withDefaults { defaults in
            var settings = WallpaperSettings.load(defaults: defaults)
            settings.takeoverShortcut = nil
            settings.save(defaults: defaults)

            XCTAssertNil(WallpaperSettings.load(defaults: defaults).takeoverShortcut)
        }
    }

    func testMalformedTakeoverShortcutFallsBackToDefault() {
        withDefaults { defaults in
            defaults.set(["keyCode": 5], forKey: WallpaperSettings.takeoverShortcutKey)
            XCTAssertEqual(WallpaperSettings.load(defaults: defaults).takeoverShortcut,
                           .defaultTakeover)
        }
    }

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

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "WallpaperSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
