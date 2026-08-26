// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import QuartzCore

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

/// Why a tile is being selected. Startup tiles are visible immediately, so
/// they must publish frames right away; a rotation replacement starts hidden
/// behind the still-running old tile, so it can afford a long fast-forward
/// to a mid-movie start.
public enum TileSelectionOccasion {
    case startup
    case rotation
}

/// Pure selection policy shared by startup and rotation. Keeping the fallback
/// decisions separate from process management makes the uniqueness behavior
/// deterministic and unit-testable.
enum TileSelectionPolicy {
    typealias Source = (Set<String>, TileSelectionOccasion) -> TileSpec?

    static func startup(source: Source, assigned: [TileSpec]) -> TileSpec? {
        let assignedROMs = Set(assigned.map(\.rom))
        return source(assignedROMs, .startup) ?? source([], .startup)
    }

    static func replacement(source: Source, displayed: [TileSpec],
                            replacing index: Int) -> TileSpec? {
        guard displayed.indices.contains(index) else { return nil }
        let allDisplayedROMs = Set(displayed.map(\.rom))
        let otherDisplayedROMs = Set(displayed.enumerated().compactMap { offset, spec in
            offset == index ? nil : spec.rom
        })
        return source(allDisplayedROMs, .rotation)
            ?? source(otherDisplayedROMs, .rotation)
            ?? source([], .rotation)
    }
}

/// Routes one window's CADisplayLink callback to the controller.
/// (CADisplayLink needs an @objc target, so this small NSObject stands in
/// for the plain-Swift controller and also remembers which window's
/// renderer fired.)
private final class DisplayLinkDriver: NSObject {
    weak var controller: WallpaperController?
    let renderer: TileGridRenderer

    init(controller: WallpaperController, renderer: TileGridRenderer) {
        self.controller = controller
        self.renderer = renderer
    }

    @objc func step(_ link: CADisplayLink) {
        controller?.render(on: renderer)
    }
}

/// Renders a columns x rows grid of NES tiles on a borderless window at
/// desktop level (behind icons) on every attached display. Each tile is a
/// nes-helper child process read via shared memory; all displays mirror the
/// same grid, so extra displays cost texture uploads and draws, not extra
/// emulator processes. Windows follow displays as they attach and detach.
public final class WallpaperController {
    /// Everything tied to one display's wallpaper window, so displays can be
    /// added and removed as a unit on hot-plug.
    private struct ScreenSlot {
        let window: WallpaperWindow
        let view: WallpaperMetalView
        let screenNumber: NSNumber?
        let renderer: TileGridRenderer
        let displayLink: CADisplayLink
        let driver: DisplayLinkDriver
        let occlusionObserver: NSObjectProtocol
    }

    private let columns: Int
    private let rows: Int
    private let filter: VideoFilter
    private let helper: URL
    private let tileSource: TileSelectionPolicy.Source
    private var slots: [ScreenSlot] = []
    private var tiles: [TileProcess] = []
    /// Selection metadata kept parallel with `tiles`, since TileProcess only
    /// owns the helper and shared-memory transport.
    private var tileSpecs: [TileSpec] = []
    private let context: MetalContext
    private var rotationTimer: Timer?
    private var rotationIndex = 0 // next tile to rotate, round-robin
    private var rotationInProgress = false
    private var shmCounter = 0    // fresh shm name for every spawned helper
    private let rotationQueue = DispatchQueue(label: "tile-rotation")
    private var observer: NSObjectProtocol?
    private var pauseObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var emulationPaused = false
    private var occlusionDebounce: DispatchWorkItem?
    /// Publishes frames to the saver and tracks whether it is consuming them.
    private let saverBridge: SaverBridge
    private let ownsSaverBridge: Bool

    /// Reduces publication/presentation to 30 fps and renders the wallpaper
    /// at logical rather than Retina resolution. Core emulation remains exact
    /// at the native NES rate so movies and game timing do not change.
    public var lowPowerMode: Bool {
        didSet {
            guard lowPowerMode != oldValue else { return }
            for slot in slots {
                slot.view.lowPowerMode = lowPowerMode
                configureFrameRate(for: slot.displayLink)
            }
            for tile in tiles { tile.setLowPowerMode(lowPowerMode) }
            writeManifest()
        }
    }

    /// Set by the UI to suspend emulation; combined with automatic pause
    /// (screen locked, all wallpaper windows occluded) in updatePauseState.
    public var userPaused = false {
        didSet { updatePauseState() }
    }

    /// Keyboard layout handed to new takeover sessions. Settable while
    /// running (a Controls change needs no restart); an active session
    /// keeps the map it started with.
    public var takeoverKeymap = TakeoverKeymap.standard

    /// When true, the tile being played live fills the takeover display,
    /// aspect-fit; other displays keep the dimmed grid. Settable while
    /// running: toggling during a session resizes immediately.
    public var fullscreenTakeover = false {
        didSet { applyFullscreenState() }
    }

    /// The active live-play session, at most one. The session tile is
    /// excluded from rotation and pause while the user is playing it.
    private var takeoverSession: TakeoverSession?

    /// The active "click a game to play" mode, mutually exclusive with a
    /// running session (picking a tile ends one and starts the other).
    private var tileSelection: TileSelectionMode?

    /// Fired on the main queue whenever a session ends, however it ends,
    /// so the menu can drop its "Stop Playing" state.
    public var onTakeoverEnded: (() -> Void)?

    /// Adapts a fixed rom/movie list to a cycling tile source, no rotation.
    public convenience init(pairs: [(rom: String, movie: String?)], columns: Int, rows: Int,
                            filter: VideoFilter = .none, lowPowerMode: Bool = false) throws {
        guard !pairs.isEmpty else {
            throw WallpaperError("need at least one rom and a positive grid")
        }
        var index = 0
        try self.init(
            tileSource: { _, _ in
                defer { index += 1 }
                let pair = pairs[index % pairs.count]
                return TileSpec(rom: pair.rom, movie: pair.movie, startFrame: 0)
            },
            rotationInterval: nil, columns: columns, rows: rows,
            filter: filter, lowPowerMode: lowPowerMode, saverBridge: nil)
    }

    /// tileSource is called once per tile at startup and once per rotation,
    /// with the ROM paths that should not be selected and the occasion of
    /// the call. It returns nil when every playable ROM is excluded.
    /// With rotationInterval set, one tile is replaced every
    /// rotationInterval / tileCount seconds, round-robin, so tiles change on
    /// a stagger rather than all at once.
    public init(tileSource: @escaping (Set<String>, TileSelectionOccasion) -> TileSpec?,
                rotationInterval: TimeInterval?,
                columns: Int, rows: Int, filter: VideoFilter = .none,
                lowPowerMode: Bool = false,
                saverBridge: SaverBridge? = nil) throws {
        guard columns > 0, rows > 0 else {
            throw WallpaperError("need at least one rom and a positive grid")
        }
        self.columns = columns
        self.rows = rows
        self.filter = filter
        self.tileSource = tileSource
        self.lowPowerMode = lowPowerMode

        let saverConfiguration = SaverConfiguration(
            columns: columns, rows: rows,
            tileWidth: filter.outputSize.width,
            tileHeight: filter.outputSize.height,
            lowPowerMode: lowPowerMode)
        if let saverBridge {
            self.saverBridge = saverBridge
            self.ownsSaverBridge = false
            saverBridge.updateConfiguration(saverConfiguration)
        } else {
            self.saverBridge = SaverBridge(configuration: saverConfiguration)
            self.ownsSaverBridge = true
        }

        helper = try Self.findHelper()
        context = try MetalContext()
        try SharedFrames.prepareTilesDirectory()
        if self.saverBridge.heartbeatPort == 0 {
            Self.log("failed to bind heartbeat socket; screensaver will show frozen frames")
        }

        // One grid of helpers total, shared by every display. Spawn them all
        // first, then open their segments: startup (ROM load, shm create)
        // overlaps across processes.
        for _ in 0..<(columns * rows) {
            // Fill without replacement while possible. A grid larger than
            // the playable library necessarily falls back to duplicates.
            guard let spec = TileSelectionPolicy.startup(
                source: tileSource, assigned: tileSpecs) else {
                throw WallpaperError("tile source produced no playable games")
            }
            tiles.append(try spawnTile(spec))
            tileSpecs.append(spec)
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

        writeManifest()

        for screen in NSScreen.screens {
            try addSlot(for: screen)
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
            self?.endTakeover() // don't leave a raised, keyboard-grabbing window
            self?.cancelTileSelection()
            self?.screenLocked = true
            self?.updatePauseState()
        })
        pauseObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.updatePauseState()
        })

        if ownsSaverBridge {
            self.saverBridge.onActivityChanged = { [weak self] _ in
                self?.saverActivityChanged()
            }
        }
    }

    /// Window, renderer, and display link for one display. Links are capped at
    /// the active 60/30 fps publication rate, and unchanged frames are gated
    /// before drawable acquisition.
    private func addSlot(for screen: NSScreen) throws {
        let window = Self.makeDesktopWindow(frame: screen.frame)
        let content = WallpaperMetalView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            device: context.device, lowPowerMode: lowPowerMode)
        window.contentView = content

        let (tileWidth, tileHeight) = filter.outputSize
        let renderer = try TileGridRenderer(
            context: context, view: content, columns: columns, rows: rows,
            tileWidth: tileWidth, tileHeight: tileHeight)
        window.orderFront(nil)

        let driver = DisplayLinkDriver(controller: self, renderer: renderer)
        let link = content.displayLink(target: driver, selector: #selector(DisplayLinkDriver.step(_:)))
        configureFrameRate(for: link)
        link.isPaused = emulationPaused
        link.add(to: .main, forMode: .common)

        let occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] _ in
            // Occlusion flaps during window ordering; settle before acting.
            self?.occlusionDebounce?.cancel()
            let work = DispatchWorkItem { self?.updatePauseState() }
            self?.occlusionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        slots.append(ScreenSlot(
            window: window,
            view: content,
            screenNumber: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            renderer: renderer,
            displayLink: link,
            driver: driver,
            occlusionObserver: occlusionObserver))
    }

    private func removeSlot(_ slot: ScreenSlot) {
        slot.displayLink.invalidate()
        NotificationCenter.default.removeObserver(slot.occlusionObserver)
        slot.window.orderOut(nil)
    }

    private func configureFrameRate(for link: CADisplayLink) {
        let fps: Float = lowPowerMode ? 30 : 60
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: fps, maximum: fps, preferred: fps)
    }

    private func updatePauseState() {
        // allSatisfy is vacuously true with no displays attached: nobody can
        // see anything, so that counts as occluded too.
        let allOccluded = slots.allSatisfy {
            !$0.window.occlusionState.contains(.visible)
        }
        // The wallpaper being invisible only matters while the saver isn't
        // showing our frames instead.
        let saverWatching = saverBridge.saverActive
        let shouldPause = userPaused
            || ((screenLocked || allOccluded) && !saverWatching)
        // Links are per-window: never draw to an invisible window, even
        // while emulation runs on for the saver's benefit.
        for slot in slots {
            slot.displayLink.isPaused = shouldPause
                || !slot.window.occlusionState.contains(.visible)
        }
        guard shouldPause != emulationPaused else { return }
        emulationPaused = shouldPause
        Self.log(shouldPause
            ? "pausing emulation (user=\(userPaused) locked=\(screenLocked) occluded=\(allOccluded))"
            : "resuming emulation\(saverWatching ? " (screensaver watching)" : "")")
        for (index, tile) in tiles.enumerated() {
            // Never pause the tile the user is playing live; sessions end on
            // screen lock, so this only bypasses user pause and occlusion.
            if index == takeoverSession?.tileIndex { continue }
            shouldPause ? tile.pause() : tile.resume()
        }
    }

    /// Re-evaluate automatic pausing after the saver heartbeat changes.
    public func saverActivityChanged() {
        updatePauseState()
    }

    // MARK: Live-play takeover

    /// The games currently on the grid, in tile order, for the
    /// "Take Over Game" menu.
    public func currentGames() -> [(tileIndex: Int, title: String)] {
        tileSpecs.enumerated().map { ($0, Self.gameTitle(for: $1)) }
    }

    /// Title of the game being played live, nil when no session is active.
    public var takeoverGameTitle: String? {
        takeoverSession.map { Self.gameTitle(for: tileSpecs[$0.tileIndex]) }
    }

    private static func gameTitle(for spec: TileSpec) -> String {
        URL(fileURLWithPath: spec.rom).deletingPathExtension().lastPathComponent
    }

    /// Raise the wallpaper on every display and let the user click the game
    /// to take over, with the hovered tile spotlit. Esc, focus loss, or
    /// cancelTileSelection back out.
    public func beginTileSelection() {
        guard tileSelection == nil, takeoverSession == nil,
              !emulationPaused, !slots.isEmpty else { return }
        let mode = TileSelectionMode(
            windows: slots.map(\.window), columns: columns, rows: rows,
            onHover: { [weak self] tile in self?.setEmphasis(.spotlight(tile)) },
            onPick: { [weak self] tile in
                guard let self else { return }
                self.cancelTileSelection()
                self.beginTakeover(tileIndex: tile)
            },
            onCancel: { [weak self] in self?.cancelTileSelection() })
        tileSelection = mode
        mode.start()
        Self.log("tile selection started")
    }

    public var tileSelectionActive: Bool { tileSelection != nil }

    /// Leave selection mode (idempotent), restoring windows and brightness.
    public func cancelTileSelection() {
        guard let mode = tileSelection else { return }
        tileSelection = nil
        mode.stop()
        setEmphasis(.none)
        // Hand focus back unless a takeover session is about to take key.
        NSApp.deactivate()
        Self.log("tile selection ended")
    }

    private func setEmphasis(_ emphasis: TileGridRenderer.Emphasis) {
        for slot in slots { slot.renderer.emphasis = emphasis }
    }

    /// Reconcile every slot's renderer with the takeover/fullscreen state;
    /// safe to call any time (no session restores every slot to the grid).
    private func applyFullscreenState() {
        let session = takeoverSession
        for slot in slots {
            slot.renderer.fullscreenTile =
                (fullscreenTakeover && slot.window === session?.window)
                    ? session?.tileIndex : nil
        }
    }

    /// Start live play on one tile: the wallpaper window on the display
    /// under the mouse is raised and captures the keyboard, and the tile's
    /// helper switches from movie playback to the live pad. One session at
    /// a time; no-op while emulation is paused.
    public func beginTakeover(tileIndex: Int) {
        cancelTileSelection()
        guard takeoverSession == nil, tiles.indices.contains(tileIndex),
              !emulationPaused else { return }
        let mouse = NSEvent.mouseLocation
        guard let slot = slots.first(where: { $0.window.frame.contains(mouse) })
            ?? slots.first else { return }

        let session = TakeoverSession(
            tileIndex: tileIndex, tile: tiles[tileIndex], window: slot.window,
            keymap: takeoverKeymap
        ) { [weak self] in self?.endTakeover() }
        takeoverSession = session
        session.start()
        setEmphasis(.spotlight(tileIndex))
        applyFullscreenState()
        // Present at full rate for input latency even in Low Power Mode;
        // the helper already publishes every frame while taken over.
        slot.displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: 60, preferred: 60)
        Self.log("takeover started on tile \(tileIndex) (\(tileSpecs[tileIndex].rom))")
    }

    /// End the active session, however it was triggered (menu, Esc, focus
    /// loss, screen lock). Restores the window, then hands the tile back to
    /// the wallpaper by rotating it to a fresh game; until the replacement
    /// publishes, the released movie plays from its start.
    public func endTakeover() {
        guard let session = takeoverSession else { return }
        takeoverSession = nil
        session.stop()
        setEmphasis(.none)
        applyFullscreenState()
        for slot in slots { configureFrameRate(for: slot.displayLink) }
        Self.log("takeover ended on tile \(session.tileIndex)")
        onTakeoverEnded?()
        rotateTile(at: session.tileIndex)
        if emulationPaused { tiles[session.tileIndex].pause() }
    }

    /// Republish the manifest whenever the set of frame files changes.
    private func writeManifest() {
        saverBridge.updateConfiguration(SaverConfiguration(
            columns: columns, rows: rows,
            tileWidth: filter.outputSize.width,
            tileHeight: filter.outputSize.height,
            lowPowerMode: lowPowerMode))
        saverBridge.publish(tiles: tiles.map(\.shmName))
    }

    public func shutdown() {
        cancelTileSelection()
        // Tear the session down without the usual end-of-session rotation:
        // every helper is about to be terminated anyway.
        if let session = takeoverSession {
            takeoverSession = nil
            session.stop()
        }
        for slot in slots { removeSlot(slot) }
        slots.removeAll()
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        for pauseObserver in pauseObservers {
            DistributedNotificationCenter.default().removeObserver(pauseObserver)
        }
        pauseObservers.removeAll()
        saverBridge.clearTiles()
        if ownsSaverBridge { saverBridge.shutdown() }
        for tile in tiles { tile.terminate() }
        tiles.removeAll()
        tileSpecs.removeAll()
        rotationInProgress = false
    }

    deinit { shutdown() }

    /// Every spawned helper gets a fresh frame-file path so a replacement
    /// never collides with the tile it is replacing.
    private func spawnTile(_ spec: TileSpec) throws -> TileProcess {
        let shmName = SharedFrames.tileURL(pid: getpid(), counter: shmCounter).path
        shmCounter += 1
        return try TileProcess(
            helper: helper, shmName: shmName, rom: spec.rom, movie: spec.movie,
            startFrame: spec.startFrame, filter: filter,
            lowPowerMode: lowPowerMode)
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
        guard !tiles.isEmpty, !emulationPaused, !rotationInProgress else { return }
        let index = rotationIndex % tiles.count
        rotationIndex = (index + 1) % tiles.count

        // The tile being played live is the user's; skip its turn.
        guard index != takeoverSession?.tileIndex else { return }
        rotateTile(at: index)
    }

    private func rotateTile(at index: Int) {
        guard tiles.indices.contains(index), !rotationInProgress else { return }

        // Prefer a game that is entirely off-screen. If the library contains
        // exactly one game per tile, allow the target tile to keep its own
        // game rather than introducing a duplicate elsewhere. Only fall back
        // to the full library when duplicates are unavoidable.
        guard let spec = TileSelectionPolicy.replacement(
            source: tileSource, displayed: tileSpecs, replacing: index) else {
            Self.log("tile source produced no replacement game")
            return
        }
        rotationInProgress = true

        let replacement: TileProcess
        do {
            replacement = try spawnTile(spec)
        } catch {
            rotationInProgress = false
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
                // tiles empties on shutdown; a session-end rotation must
                // complete even when the rotation timer was never created.
                guard let self, index < self.tiles.count else {
                    replacement.terminate() // controller shut down mid-rotation
                    return
                }
                defer { self.rotationInProgress = false }
                if index == self.takeoverSession?.tileIndex {
                    // The user took this tile over while its replacement was
                    // starting; never swap a tile out from under a session.
                    replacement.terminate()
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
                self.tileSpecs[index] = spec
                self.writeManifest()
                // The replacement restarts frame_count; force a re-upload so
                // a coincidental match can't leave the old game on screen.
                for slot in self.slots { slot.renderer.invalidateTile(index) }
                // Pause may have flipped while the replacement was starting.
                if self.emulationPaused { replacement.pause() }
            }
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(msg)\n".utf8))
    }

    /// Display-link callback for one window: upload changed tiles, draw.
    /// Every window draws the whole tile array — displays mirror each other.
    fileprivate func render(on renderer: TileGridRenderer) {
        renderer.draw(tiles: tiles, range: 0..<tiles.count)
    }

    /// Reconcile windows with the attached displays: resize survivors, drop
    /// windows whose display is gone, add windows for new displays.
    private func screensChanged() {
        // Selection mode holds per-window saved state; displays changing
        // under it would restore the wrong windows. Start over instead.
        cancelTileSelection()
        var departed = slots
        slots.removeAll()
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if let index = departed.firstIndex(where: { $0.screenNumber == number }) {
                let slot = departed.remove(at: index)
                slot.window.setFrame(screen.frame, display: true)
                slot.window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
                // The view's layout pass resizes the drawable; tile geometry
                // is recomputed from drawableSize on every draw.
                slots.append(slot)
            } else {
                do {
                    try addSlot(for: screen)
                } catch {
                    Self.log("failed to add wallpaper window for new display: \(error)")
                }
            }
        }
        for slot in departed { removeSlot(slot) }
        // A session whose raised window just left with its display is over.
        if let session = takeoverSession,
           !slots.contains(where: { $0.window === session.window }) {
            endTakeover()
        }
        // New slots default to the grid; re-assert fullscreen on a survivor.
        applyFullscreenState()
        // Displays coming or going changes what "all occluded" means.
        updatePauseState()
    }

    private static func makeDesktopWindow(frame: NSRect) -> WallpaperWindow {
        let window = WallpaperWindow(
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
