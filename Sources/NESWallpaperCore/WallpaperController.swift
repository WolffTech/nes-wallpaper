import AppKit

public struct WallpaperError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What one tile should play: a ROM, an optional FM2 movie, and the movie
/// frame to fast-forward to before showing anything (0 = from the start).
public struct TileSpec {
    public let rom: String
    public let movie: String?
    public let startFrame: Int

    public init(rom: String, movie: String?, startFrame: Int = 0) {
        self.rom = rom
        self.movie = movie
        self.startFrame = startFrame
    }
}

/// Renders a columns x rows grid of NES tiles on a borderless window at
/// desktop level (behind icons) on each requested screen. Each tile is a
/// nes-helper child process read via shared memory.
/// Routes one window's CADisplayLink callback to the controller.
/// (CADisplayLink needs an @objc target, so this small NSObject stands in
/// for the plain-Swift controller and also remembers which window fired.)
private final class DisplayLinkDriver: NSObject {
    weak var controller: WallpaperController?
    let windowIndex: Int

    init(controller: WallpaperController, windowIndex: Int) {
        self.controller = controller
        self.windowIndex = windowIndex
    }

    @objc func step(_ link: CADisplayLink) {
        controller?.renderWindow(windowIndex)
    }
}

public final class WallpaperController {
    private let columns: Int
    private let rows: Int
    private let filter: VideoFilter
    private let helper: URL
    private let tileSource: () -> TileSpec
    private var windows: [NSWindow] = []
    private var screenNumbers: [NSNumber?] = [] // per window, for relayout
    private var tiles: [TileProcess] = []       // parallel to renderers' slots
    private let context: MetalContext
    private var renderers: [TileGridRenderer] = [] // one per window
    private var displayLinks: [CADisplayLink] = []
    private var linkDrivers: [DisplayLinkDriver] = []
    private var rotationTimer: Timer?
    private var rotationIndex = 0 // next tile to rotate, round-robin
    private var shmCounter = 0    // fresh shm name for every spawned helper
    private let rotationQueue = DispatchQueue(label: "tile-rotation")
    private var observer: NSObjectProtocol?
    private var pauseObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var emulationPaused = false
    private var occlusionDebounce: DispatchWorkItem?

    /// Set by the UI to suspend emulation; combined with automatic pause
    /// (screen locked, all wallpaper windows occluded) in updatePauseState.
    public var userPaused = false {
        didSet { updatePauseState() }
    }

    /// Adapts a fixed rom/movie list to a cycling tile source, no rotation.
    public convenience init(pairs: [(rom: String, movie: String?)], columns: Int, rows: Int,
                            screens: [NSScreen], filter: VideoFilter = .none) throws {
        guard !pairs.isEmpty else {
            throw WallpaperError("need at least one rom, one screen, and a positive grid")
        }
        var index = 0
        try self.init(
            tileSource: {
                defer { index += 1 }
                let pair = pairs[index % pairs.count]
                return TileSpec(rom: pair.rom, movie: pair.movie, startFrame: 0)
            },
            rotationInterval: nil, columns: columns, rows: rows, screens: screens,
            filter: filter)
    }

    /// tileSource is called once per tile at startup and once per rotation.
    /// With rotationInterval set, one tile is replaced every
    /// rotationInterval / tileCount seconds, round-robin, so tiles change on
    /// a stagger rather than all at once.
    public init(tileSource: @escaping () -> TileSpec, rotationInterval: TimeInterval?,
                columns: Int, rows: Int, screens: [NSScreen],
                filter: VideoFilter = .none) throws {
        guard columns > 0, rows > 0, !screens.isEmpty else {
            throw WallpaperError("need at least one rom, one screen, and a positive grid")
        }
        self.columns = columns
        self.rows = rows
        self.filter = filter
        self.tileSource = tileSource

        helper = try Self.findHelper()
        context = try MetalContext()

        // Spawn every helper first, then open their segments: startup
        // (ROM load, shm create) overlaps across processes.
        let (tileWidth, tileHeight) = filter.outputSize
        for screen in screens {
            let window = Self.makeDesktopWindow(frame: screen.frame)
            let content = WallpaperMetalView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                device: context.device)
            window.contentView = content

            for _ in 0..<(columns * rows) {
                tiles.append(try spawnTile(tileSource()))
            }
            renderers.append(try TileGridRenderer(
                context: context, view: content, columns: columns, rows: rows,
                tileWidth: tileWidth, tileHeight: tileHeight))

            windows.append(window)
            screenNumbers.append(
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            window.orderFront(nil)
        }

        for tile in tiles {
            guard tile.openSharedMemory() else {
                Self.log("helper for \(tile.shmName) never published; tile stays black")
                tile.terminate()
                continue
            }
            if let size = tile.frameSize, size != filter.outputSize {
                Self.log("helper for \(tile.shmName) publishes \(size) but filter "
                    + "\(filter.rawValue) expects \(filter.outputSize); tile stays black")
                tile.terminate()
            }
        }

        // One display link per window: each runs at its display's native
        // cadence. Uploads are gated on frame_count, so a 120 Hz ProMotion
        // display costs extra draws but no extra texture uploads.
        for (windowIndex, window) in windows.enumerated() {
            guard let content = window.contentView else { continue }
            let driver = DisplayLinkDriver(controller: self, windowIndex: windowIndex)
            let link = content.displayLink(target: driver, selector: #selector(DisplayLinkDriver.step(_:)))
            link.add(to: .main, forMode: .common)
            linkDrivers.append(driver)
            displayLinks.append(link)
        }

        if let rotationInterval, rotationInterval > 0, !tiles.isEmpty {
            let rotationTimer = Timer(
                timeInterval: rotationInterval / Double(tiles.count), repeats: true
            ) { [weak self] _ in
                self?.rotateNextTile()
            }
            RunLoop.main.add(rotationTimer, forMode: .common)
            self.rotationTimer = rotationTimer
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }

        // Emulating all day is wasteful when nobody can see the wallpaper:
        // pause the helpers while the screen is locked or every wallpaper
        // window is fully covered (e.g. a fullscreen app).
        let distributed = DistributedNotificationCenter.default()
        pauseObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.updatePauseState()
        })
        pauseObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.updatePauseState()
        })
        for window in windows {
            pauseObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                // Occlusion flaps during window ordering; settle before acting.
                self?.occlusionDebounce?.cancel()
                let work = DispatchWorkItem { self?.updatePauseState() }
                self?.occlusionDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            })
        }
    }

    private func updatePauseState() {
        let allOccluded = !windows.isEmpty && windows.allSatisfy {
            !$0.occlusionState.contains(.visible)
        }
        let shouldPause = userPaused || screenLocked || allOccluded
        guard shouldPause != emulationPaused else { return }
        emulationPaused = shouldPause
        Self.log(shouldPause
            ? "pausing emulation (user=\(userPaused) locked=\(screenLocked) occluded=\(allOccluded))"
            : "resuming emulation")
        for tile in tiles {
            shouldPause ? tile.pause() : tile.resume()
        }
        // Emulators stop via stdin; the links stop the app's GPU work too.
        for link in displayLinks { link.isPaused = shouldPause }
    }

    public func shutdown() {
        for link in displayLinks { link.invalidate() }
        displayLinks.removeAll()
        linkDrivers.removeAll()
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        for pauseObserver in pauseObservers {
            NotificationCenter.default.removeObserver(pauseObserver)
            DistributedNotificationCenter.default().removeObserver(pauseObserver)
        }
        pauseObservers.removeAll()
        for tile in tiles { tile.terminate() }
        tiles.removeAll()
        for window in windows { window.orderOut(nil) }
    }

    deinit { shutdown() }

    /// Every spawned helper gets a fresh shm name so a replacement never
    /// collides with the tile it is replacing. Names stay under the macOS
    /// 31-char PSHMNAMLEN cap.
    private func spawnTile(_ spec: TileSpec) throws -> TileProcess {
        let shmName = "/nes.\(getpid()).\(shmCounter)"
        shmCounter += 1
        return try TileProcess(
            helper: helper, shmName: shmName, rom: spec.rom, movie: spec.movie,
            startFrame: spec.startFrame, filter: filter)
    }

    /// Replace one tile, round-robin, without blocking the main thread:
    /// spawn the replacement, wait on a background queue until it is actually
    /// publishing frames (ROM load + optional fast-forward can take seconds),
    /// and only then — back on the main queue — terminate the old helper and
    /// swap the new one in. The layer keeps showing the old game until then.
    /// If the replacement never publishes, the old tile keeps running until
    /// the next rotation attempt.
    private func rotateNextTile() {
        // Don't churn helpers while nobody can see the wallpaper.
        guard !tiles.isEmpty, !emulationPaused else { return }
        let index = rotationIndex % tiles.count
        rotationIndex = (index + 1) % tiles.count

        let replacement: TileProcess
        do {
            replacement = try spawnTile(tileSource())
        } catch {
            Self.log("failed to spawn replacement tile: \(error)")
            return
        }

        rotationQueue.async { [weak self] in
            var live = replacement.openSharedMemory(timeout: 30)
            if live {
                // The segment appears before any fast-forward, so also wait
                // for the first published frame: swapping earlier would show
                // a black tile for the whole fast-forward.
                let deadline = Date(timeIntervalSinceNow: 30)
                while replacement.frameCount == 0, Date() < deadline { usleep(50_000) }
                live = replacement.frameCount > 0
            }
            DispatchQueue.main.async {
                guard let self, self.rotationTimer != nil, index < self.tiles.count else {
                    replacement.terminate() // controller shut down mid-rotation
                    return
                }
                guard live else {
                    Self.log("replacement helper for \(replacement.shmName) never published; keeping old tile")
                    replacement.terminate()
                    return
                }
                if let size = replacement.frameSize, size != self.filter.outputSize {
                    Self.log("replacement helper for \(replacement.shmName) publishes \(size), expected \(self.filter.outputSize); keeping old tile")
                    replacement.terminate()
                    return
                }
                self.tiles[index].terminate()
                self.tiles[index] = replacement
                // The replacement restarts frame_count; force a re-upload so
                // a coincidental match can't leave the old game on screen.
                let tilesPerWindow = self.columns * self.rows
                if index / tilesPerWindow < self.renderers.count {
                    self.renderers[index / tilesPerWindow].invalidateTile(index % tilesPerWindow)
                }
                // Pause may have flipped while the replacement was starting.
                if self.emulationPaused { replacement.pause() }
            }
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(msg)\n".utf8))
    }

    /// Display-link callback for one window: upload changed tiles, draw.
    fileprivate func renderWindow(_ windowIndex: Int) {
        guard windowIndex < renderers.count else { return }
        let base = windowIndex * columns * rows
        renderers[windowIndex].draw(tiles: tiles, range: base..<(base + columns * rows))
    }

    private func screensChanged() {
        for (index, window) in windows.enumerated() {
            let match = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    == screenNumbers[index]
            }
            guard let screen = match ?? NSScreen.main else { continue }
            window.setFrame(screen.frame, display: true)
            window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
            // The view's layout pass resizes the drawable; tile geometry is
            // recomputed from drawableSize on every draw.
        }
    }

    private static func makeDesktopWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        return window
    }

    /// nes-helper is installed next to the app executable.
    private static func findHelper() throws -> URL {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let helper = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("nes-helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw WallpaperError("nes-helper not found at \(helper.path)")
        }
        return helper
    }
}
