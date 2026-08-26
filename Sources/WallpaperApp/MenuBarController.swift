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
    static let fullscreenTakeoverKey = "FullscreenTakeover"

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
    /// Fill the takeover display with the played tile during live play.
    var fullscreenTakeover: Bool

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
            takeoverShortcut: shortcut,
            fullscreenTakeover: defaults.bool(forKey: fullscreenTakeoverKey))
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
        defaults.set(fullscreenTakeover, forKey: Self.fullscreenTakeoverKey)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Playback exists while either presentation needs it. Desktop demand also
/// controls whether the running grid owns wallpaper windows.
struct PlaybackDemand: Equatable {
    var desktop = true
    var saver = false

    var needsPlayback: Bool { desktop || saver }
}

/// Owns the status item and the wallpaper lifecycle in menu-bar mode.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var controller: WallpaperController?
    private var settingsWindow: SettingsWindowController?
    private var browserWindow: TASBrowserWindowController?
    private var takeoverHotKey: GlobalHotKey?
    private(set) var updaterController: UpdaterController?
    private var saverBridge: SaverBridge?
    private var demand = PlaybackDemand()

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

        // Games first: playing one and finding more, ordered by use.
        takeoverItem.target = self
        menu.addItem(takeoverItem)

        let browserItem = NSMenuItem(title: "Browse Tool-Assisted Speedruns",
                                     action: #selector(openBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)

        // Wallpaper/emulation state, the most drastic action last.
        menu.addItem(.separator())
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        lowPowerItem.title = "Low Power Mode"
        lowPowerItem.target = self
        lowPowerItem.action = #selector(toggleLowPowerMode)
        menu.addItem(lowPowerItem)

        startStopItem.target = self
        startStopItem.action = #selector(toggleWallpaper)
        menu.addItem(startStopItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings",
                                      action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // KVO on canCheckForUpdates owns this item's enabled state, so it
        // needs no refreshMenuTitles() handling.
        if UpdaterController.available {
            let updater = UpdaterController()
            let checkItem = NSMenuItem(title: "Check for Updates",
                                       action: nil, keyEquivalent: "")
            updater.bind(menuItem: checkItem)
            menu.addItem(checkItem)
            updaterController = updater
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NES Wallpaper",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        let settings = WallpaperSettings.load()
        let bridge = SaverBridge(configuration: Self.saverConfiguration(settings))
        bridge.onActivityChanged = { [weak self] active in
            self?.demand.saver = active
            self?.reconcilePlayback(interactive: false)
        }
        saverBridge = bridge
        refreshMenuTitles()

        // Desktop demand starts enabled for backward compatibility.
        reconcilePlayback(interactive: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        startStopItem.title = demand.desktop ? "Stop Wallpaper" : "Start Wallpaper"
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
        guard demand.desktop, let controller, !userWantsPause else {
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
        demand.desktop.toggle()
        reconcilePlayback(interactive: demand.desktop)
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
        saverBridge?.updateConfiguration(Self.saverConfiguration(settings))
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
    /// new values. A running grid restarts so every helper uses them.
    func settingsApplied() {
        let settings = WallpaperSettings.load()
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        stopPlayback()
        saverBridge?.updateConfiguration(Self.saverConfiguration(settings))
        reconcilePlayback(interactive: demand.desktop)
    }

    /// Called by the Controls tab after each saved change: a keymap swap
    /// needs no restart, only a fresh map for the next takeover (an active
    /// session keeps the one it started with), and the fullscreen toggle
    /// applies live to the running controller.
    func controlsChanged() {
        let settings = WallpaperSettings.load()
        controller?.takeoverKeymap =
            TakeoverKeymap(buttonAssignments: settings.takeoverControls)
        controller?.fullscreenTakeover = settings.fullscreenTakeover
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
        -> ((Set<String>, TileSelectionOccasion) -> TileSpec?)?
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
        // Startup tiles play from power-on so the grid appears immediately;
        // random mid-movie starts are reserved for rotations, where the old
        // tile covers the fast-forward.
        return { excludedROMs, occasion in
            library.randomTileSpec(
                includeROMsWithoutMovies: includeROMs,
                excludingROMs: excludedROMs,
                randomizedStart: occasion == .rotation)
        }
    }

    private static func saverConfiguration(_ settings: WallpaperSettings)
        -> SaverConfiguration
    {
        SaverConfiguration(
            columns: settings.columns, rows: settings.rows,
            tileWidth: settings.videoFilter.outputSize.width,
            tileHeight: settings.videoFilter.outputSize.height,
            lowPowerMode: settings.lowPowerMode)
    }

    private func reconcilePlayback(interactive: Bool) {
        demand.saver = saverBridge?.saverActive ?? false
        guard demand.needsPlayback else {
            stopPlayback()
            return
        }
        if let controller {
            do {
                try controller.setDesktopPresentationEnabled(demand.desktop)
                controller.saverActivityChanged()
            } catch {
                log("\(error)")
                if interactive { showStartError(error) }
            }
            refreshMenuTitles()
            return
        }
        startPlayback(interactive: interactive)
    }

    private func startPlayback(interactive: Bool) {
        let settings = WallpaperSettings.load()
        guard let tileSource = Self.makeTileSource(settings: settings) else {
            log("no configured rom/movie matches; playback not started")
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
                openSettings()
            }
            refreshMenuTitles()
            return
        }
        guard let saverBridge else { return }
        do {
            let controller = try WallpaperController(
                tileSource: tileSource,
                rotationInterval: settings.rotationInterval,
                columns: settings.columns, rows: settings.rows,
                filter: settings.videoFilter,
                lowPowerMode: settings.lowPowerMode,
                desktopPresentationEnabled: demand.desktop,
                saverBridge: saverBridge)
            controller.userPaused = userWantsPause
            controller.takeoverKeymap =
                TakeoverKeymap(buttonAssignments: settings.takeoverControls)
            controller.fullscreenTakeover = settings.fullscreenTakeover
            controller.onTakeoverEnded = { [weak self] in self?.refreshMenuTitles() }
            self.controller = controller
        } catch {
            log("\(error)")
            if interactive { showStartError(error) }
        }
        refreshMenuTitles()
    }

    private func showStartError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Start Wallpaper"
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func stopPlayback() {
        controller?.shutdown()
        controller = nil
        refreshMenuTitles()
    }

    func shutdown() {
        stopPlayback()
        saverBridge?.shutdown()
        saverBridge = nil
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(msg)\n".utf8))
    }
}
