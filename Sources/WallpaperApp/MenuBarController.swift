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

    var romsDir: String?
    var moviesDir: String?
    var columns: Int
    var rows: Int
    var rotationMinutes: Int // 0 = never rotate

    var rotationInterval: TimeInterval? {
        rotationMinutes > 0 ? TimeInterval(rotationMinutes) * 60 : nil
    }

    static func load() -> WallpaperSettings {
        let defaults = UserDefaults.standard
        return WallpaperSettings(
            romsDir: defaults.string(forKey: romsDirKey),
            moviesDir: defaults.string(forKey: moviesDirKey),
            columns: (defaults.object(forKey: columnsKey) as? Int ?? 3).clamped(to: 1...8),
            rows: (defaults.object(forKey: rowsKey) as? Int ?? 2).clamped(to: 1...6),
            rotationMinutes: max(0, defaults.object(forKey: rotationMinutesKey) as? Int ?? 10))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(romsDir, forKey: Self.romsDirKey)
        defaults.set(moviesDir, forKey: Self.moviesDirKey)
        defaults.set(columns, forKey: Self.columnsKey)
        defaults.set(rows, forKey: Self.rowsKey)
        defaults.set(rotationMinutes, forKey: Self.rotationMinutesKey)
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

    /// User's pause intent; sticks across stop/start and screen lock (the
    /// controller combines it with its own automatic pause conditions).
    private var userWantsPause = false

    private let startStopItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    override init() {
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "tv.fill",
                               accessibilityDescription: "NES Wallpaper") {
            item.button?.image = image
        } else {
            item.length = NSStatusItem.variableLength
            item.button?.title = "NES"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        startStopItem.target = self
        startStopItem.action = #selector(toggleWallpaper)
        menu.addItem(startStopItem)

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
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

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(menuBar: self)
        }
        settingsWindow?.show()
    }

    /// Called by the settings window's Apply button after it has saved the
    /// new values: restart the wallpaper only if it is currently running.
    func settingsApplied() {
        guard controller != nil else { return }
        startWallpaper(interactive: true)
    }

    /// Build a tile source from the configured library: each tile plays a
    /// random matched rom/movie pair starting at a random point in the first
    /// 70% of the movie (same policy as the CLI's library mode). Returns nil
    /// when the folders are unset or yield no matches.
    private static func makeTileSource(settings: WallpaperSettings) -> (() -> TileSpec)? {
        guard let romsDir = settings.romsDir, !romsDir.isEmpty,
              let moviesDir = settings.moviesDir, !moviesDir.isEmpty else { return nil }
        let library = ContentLibrary(
            romsDir: URL(fileURLWithPath: romsDir, isDirectory: true),
            moviesDir: URL(fileURLWithPath: moviesDir, isDirectory: true))
        guard !library.matches.isEmpty else { return nil }
        return {
            let match = library.randomMatch()!
            let maxStart = Int(Double(match.frameCount) * 0.7)
            return TileSpec(
                rom: match.romURL.path,
                movie: match.movieURL.path,
                startFrame: maxStart > 0 ? Int.random(in: 0...maxStart) : 0)
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
                    their header, so at least one movie must match a ROM.
                    """
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            openSettings()
            refreshMenuTitles()
            return
        }
        guard let screen = NSScreen.main else {
            log("no screen")
            return
        }
        do {
            let controller = try WallpaperController(
                tileSource: tileSource,
                rotationInterval: settings.rotationInterval,
                columns: settings.columns, rows: settings.rows, screens: [screen])
            controller.userPaused = userWantsPause
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
