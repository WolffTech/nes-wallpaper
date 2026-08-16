// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import NESWallpaperCore

/// Menu-bar mode settings, persisted in UserDefaults (for this unbundled
/// executable the defaults domain is the executable name, "nes-wallpaper").
struct WallpaperSettings {
    static let romsDirKey = "RomsDirectory"
    static let moviesDirKey = "MoviesDirectory"
    static let columnsKey = "GridColumns"
    static let rowsKey = "GridRows"
    static let rotationMinutesKey = "RotationMinutes"
    static let includeROMsWithoutMoviesKey = "IncludeROMsWithoutMovies"
    static let videoFilterKey = "VideoFilter"
    static let lowPowerModeKey = "LowPowerMode"
    static let takeoverControlsKey = "TakeoverControls"
    static let takeoverShortcutKey = "TakeoverShortcut"
    static let showDockIconKey = "ShowDockIcon"

    var romsDir: String?
    var moviesDir: String?
    var columns: Int
    var rows: Int
    var rotationMinutes: Int // 0 = never rotate
    var includeROMsWithoutMovies: Bool
    var videoFilter: VideoFilter
    var lowPowerMode: Bool
    var showDockIcon: Bool
    /// Takeover key overrides, button name → keyCode; empty = all defaults
    /// (see TakeoverKeymap.init(buttonAssignments:)).
    var takeoverControls: [String: Int]
    /// nil means the user explicitly disabled the global shortcut. A missing
    /// preference uses GlobalShortcut.defaultTakeover.
    var takeoverShortcut: GlobalShortcut?

    var rotationInterval: TimeInterval? {
        rotationMinutes > 0 ? TimeInterval(rotationMinutes) * 60 : nil
    }

    static func load(defaults: UserDefaults = .standard) -> WallpaperSettings {
        let shortcut: GlobalShortcut?
        if defaults.object(forKey: takeoverShortcutKey) == nil {
            shortcut = .defaultTakeover
        } else if let stored = defaults.dictionary(forKey: takeoverShortcutKey),
                  stored.isEmpty {
            shortcut = nil
        } else if let stored = defaults.dictionary(forKey: takeoverShortcutKey) {
            shortcut = GlobalShortcut(storedValue: stored) ?? .defaultTakeover
        } else {
            shortcut = .defaultTakeover
        }
        return WallpaperSettings(
            romsDir: defaults.string(forKey: romsDirKey),
            moviesDir: defaults.string(forKey: moviesDirKey),
            columns: (defaults.object(forKey: columnsKey) as? Int ?? 3).clamped(to: 1...8),
            rows: (defaults.object(forKey: rowsKey) as? Int ?? 2).clamped(to: 1...6),
            rotationMinutes: max(0, defaults.object(forKey: rotationMinutesKey) as? Int ?? 10),
            includeROMsWithoutMovies: defaults.object(
                forKey: includeROMsWithoutMoviesKey) as? Bool ?? true,
            videoFilter: VideoFilter(
                rawValue: defaults.string(forKey: videoFilterKey) ?? "") ?? .none,
            lowPowerMode: defaults.bool(forKey: lowPowerModeKey),
            showDockIcon: defaults.bool(forKey: showDockIconKey),
            takeoverControls: defaults.dictionary(forKey: takeoverControlsKey)?
                .compactMapValues { $0 as? Int } ?? [:],
            takeoverShortcut: shortcut)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(romsDir, forKey: Self.romsDirKey)
        defaults.set(moviesDir, forKey: Self.moviesDirKey)
        defaults.set(columns, forKey: Self.columnsKey)
        defaults.set(rows, forKey: Self.rowsKey)
        defaults.set(rotationMinutes, forKey: Self.rotationMinutesKey)
        defaults.set(includeROMsWithoutMovies, forKey: Self.includeROMsWithoutMoviesKey)
        defaults.set(videoFilter.rawValue, forKey: Self.videoFilterKey)
        defaults.set(lowPowerMode, forKey: Self.lowPowerModeKey)
        defaults.set(showDockIcon, forKey: Self.showDockIconKey)
        defaults.set(takeoverControls, forKey: Self.takeoverControlsKey)
        defaults.set(takeoverShortcut?.storedValue ?? [:],
                     forKey: Self.takeoverShortcutKey)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Owns the status item and the wallpaper lifecycle in menu-bar mode.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var controller: WallpaperController?
    private var settingsWindow: SettingsWindowController?
    private var browserWindow: TASBrowserWindowController?
    private var takeoverHotKey: GlobalHotKey?

    /// User's pause intent; sticks across stop/start and screen lock (the
    /// controller combines it with its own automatic pause conditions).
    private var userWantsPause = false

    private let startStopItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let lowPowerItem = NSMenuItem()
    private let takeoverItem = NSMenuItem()

    override init() {
        super.init()

        do {
            let hotKey = try GlobalHotKey { [weak self] in self?.selectGameByClicking() }
            takeoverHotKey = hotKey
            try hotKey.setShortcut(WallpaperSettings.load().takeoverShortcut)
        } catch {
            log("global takeover shortcut unavailable: \(error.localizedDescription)")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.makeImage()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        startStopItem.target = self
        startStopItem.action = #selector(toggleWallpaper)
        menu.addItem(startStopItem)

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        takeoverItem.target = self
        menu.addItem(takeoverItem)

        menu.addItem(.separator())
        let browserItem = NSMenuItem(title: "Browse TASVideos",
                                     action: #selector(openBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(.separator())
        lowPowerItem.title = "Low Power Mode"
        lowPowerItem.target = self
        lowPowerItem.action = #selector(toggleLowPowerMode)
        menu.addItem(lowPowerItem)

        let settingsItem = NSMenuItem(title: "Settings",
                                      action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        refreshMenuTitles()

        // Start automatically when the configured folders already yield
        // matches; otherwise wait for the user to open Settings.
        startWallpaper(interactive: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        startStopItem.title = controller == nil ? "Start Wallpaper" : "Stop Wallpaper"
        pauseItem.title = userWantsPause ? "Resume" : "Pause"
        pauseItem.isEnabled = controller != nil
        lowPowerItem.state = WallpaperSettings.load().lowPowerMode ? .on : .off
        refreshTakeoverItem()
    }

    /// "Take Over Game ▸" submenu (click-to-select plus the games on the
    /// grid), or a plain "Stop Playing <game>" / "Cancel Game Selection"
    /// item while one of those is running.
    private func refreshTakeoverItem() {
        if let title = controller?.takeoverGameTitle {
            takeoverItem.title = "Stop Playing \(title)"
            takeoverItem.submenu = nil
            takeoverItem.action = #selector(stopTakeover)
            takeoverItem.isEnabled = true
            return
        }
        if controller?.tileSelectionActive == true {
            takeoverItem.title = "Cancel Game Selection"
            takeoverItem.submenu = nil
            takeoverItem.action = #selector(cancelTileSelection)
            takeoverItem.isEnabled = true
            return
        }
        takeoverItem.title = "Take Over Game"
        takeoverItem.action = nil
        guard let controller, !userWantsPause else {
            takeoverItem.submenu = nil
            takeoverItem.isEnabled = false
            return
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var clickTitle = "Click a Game on Screen"
        if let shortcut = WallpaperSettings.load().takeoverShortcut {
            clickTitle += " (\(shortcut.displayName))"
        }
        let clickItem = NSMenuItem(title: clickTitle,
                                   action: #selector(selectGameByClicking), keyEquivalent: "")
        clickItem.target = self
        submenu.addItem(clickItem)
        submenu.addItem(.separator())
        for game in controller.currentGames() {
            let item = NSMenuItem(title: game.title,
                                  action: #selector(takeOverGame(_:)), keyEquivalent: "")
            item.target = self
            item.tag = game.tileIndex
            submenu.addItem(item)
        }
        takeoverItem.submenu = submenu
        takeoverItem.isEnabled = true
    }

    @objc private func takeOverGame(_ sender: NSMenuItem) {
        controller?.beginTakeover(tileIndex: sender.tag)
        refreshMenuTitles()
    }

    @objc private func selectGameByClicking() {
        controller?.beginTileSelection()
        refreshMenuTitles()
    }

    @objc private func cancelTileSelection() {
        controller?.cancelTileSelection()
        refreshMenuTitles()
    }

    @objc private func stopTakeover() {
        controller?.endTakeover()
        refreshMenuTitles()
    }

    @objc private func toggleWallpaper() {
        if controller != nil {
            stopWallpaper()
        } else {
            startWallpaper(interactive: true)
        }
    }

    @objc private func togglePause() {
        userWantsPause.toggle()
        controller?.userPaused = userWantsPause
        refreshMenuTitles()
    }

    @objc private func toggleLowPowerMode() {
        var settings = WallpaperSettings.load()
        settings.lowPowerMode.toggle()
        settings.save()
        controller?.lowPowerMode = settings.lowPowerMode
        refreshMenuTitles()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(menuBar: self)
        }
        settingsWindow?.show()
    }

    @objc func openBrowser() {
        if browserWindow == nil {
            browserWindow = TASBrowserWindowController()
        }
        browserWindow?.show()
    }

    /// Called by the settings window's Apply button after it has saved the
    /// new values: restart the wallpaper only if it is currently running.
    func settingsApplied() {
        let settings = WallpaperSettings.load()
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        guard controller != nil else { return }
        startWallpaper(interactive: true)
    }

    /// Called by the Controls tab after each saved key change: a keymap
    /// swap needs no restart, only a fresh map for the next takeover (an
    /// active session keeps the one it started with).
    func controlsChanged() {
        controller?.takeoverKeymap =
            TakeoverKeymap(buttonAssignments: WallpaperSettings.load().takeoverControls)
    }

    /// Suspend registration while the recorder has focus so the old shortcut
    /// reaches the settings window, then restore the persisted assignment.
    func shortcutRecordingChanged(_ recording: Bool) {
        do {
            try takeoverHotKey?.setShortcut(
                recording ? nil : WallpaperSettings.load().takeoverShortcut)
        } catch {
            log("global takeover shortcut unavailable: \(error.localizedDescription)")
        }
    }

    /// Register first and persist only after success. GlobalHotKey restores
    /// the previous registration if the new chord is unavailable.
    func changeTakeoverShortcut(_ shortcut: GlobalShortcut?) -> String? {
        guard let takeoverHotKey else {
            return "Global shortcuts aren\u{2019}t available right now."
        }
        do {
            try takeoverHotKey.setShortcut(shortcut)
            var settings = WallpaperSettings.load()
            settings.takeoverShortcut = shortcut
            settings.save()
            refreshMenuTitles()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Build a tile source from the configured library: each tile plays a
    /// random pick from the library (same policy as the CLI's library mode).
    /// Returns nil when the folders are unset or yield nothing playable.
    private static func makeTileSource(settings: WallpaperSettings)
        -> ((Set<String>) -> TileSpec?)?
    {
        guard let romsDir = settings.romsDir, !romsDir.isEmpty,
              let moviesDir = settings.moviesDir, !moviesDir.isEmpty else { return nil }
        let library = ContentLibrary(
            romsDir: URL(fileURLWithPath: romsDir, isDirectory: true),
            moviesDir: URL(fileURLWithPath: moviesDir, isDirectory: true))
        let includeROMs = settings.includeROMsWithoutMovies
        guard library.randomTileSpec(includeROMsWithoutMovies: includeROMs) != nil else {
            return nil
        }
        // The library is immutable; exclusions may temporarily exhaust it.
        return { excludedROMs in
            library.randomTileSpec(
                includeROMsWithoutMovies: includeROMs,
                excludingROMs: excludedROMs)
        }
    }

    private func startWallpaper(interactive: Bool) {
        stopWallpaper()
        let settings = WallpaperSettings.load()
        guard let tileSource = Self.makeTileSource(settings: settings) else {
            log("no configured rom/movie matches; wallpaper not started")
            if interactive {
                let alert = NSAlert()
                alert.messageText = "Nothing to Play"
                alert.informativeText = """
                    Set a ROM folder and a Movies folder in Settings. Movies \
                    (.fm2) are matched to ROMs (.nes) by the checksum in \
                    their header. With "Include games without movies" on, \
                    ROMs alone are enough; otherwise at least one movie must \
                    match a ROM.
                    """
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            openSettings()
            refreshMenuTitles()
            return
        }
        do {
            let controller = try WallpaperController(
                tileSource: tileSource,
                rotationInterval: settings.rotationInterval,
                columns: settings.columns, rows: settings.rows,
                filter: settings.videoFilter,
                lowPowerMode: settings.lowPowerMode)
            controller.userPaused = userWantsPause
            controller.takeoverKeymap =
                TakeoverKeymap(buttonAssignments: settings.takeoverControls)
            controller.onTakeoverEnded = { [weak self] in self?.refreshMenuTitles() }
            self.controller = controller
        } catch {
            log("\(error)")
            if interactive {
                let alert = NSAlert()
                alert.messageText = "Could Not Start Wallpaper"
                alert.informativeText = "\(error)"
                alert.alertStyle = .critical
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        refreshMenuTitles()
    }

    private func stopWallpaper() {
        controller?.shutdown()
        controller = nil
        refreshMenuTitles()
    }

    func shutdown() {
        stopWallpaper()
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(msg)\n".utf8))
    }
}
