// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Sparkle

/// Sparkle auto-updates for menu-bar mode. Like SMAppService (see
/// LoginItemModel), this only works from the installed .app bundle: the bare
/// SwiftPM executable has no Info.plist, so Sparkle would report a fatal
/// setup error over the missing SUFeedURL/SUPublicEDKey.
final class UpdaterController {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var menuItemObservation: NSKeyValueObservation?

    var updater: SPUUpdater { controller.updater }

    /// Wires "Check for Updates…" to Sparkle. The status menu has
    /// autoenablesItems = false, so the enabled state is driven by KVO on
    /// SPUUpdater.canCheckForUpdates, which goes false while a check or an
    /// update is already in progress.
    func bind(menuItem item: NSMenuItem) {
        item.target = controller
        item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        menuItemObservation = updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]) { [weak item] updater, _ in
            item?.isEnabled = updater.canCheckForUpdates
        }
    }
}
