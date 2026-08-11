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
public final class WallpaperController {
    private let columns: Int
    private let rows: Int
    private let helper: URL
    private let tileSource: () -> TileSpec
    private var windows: [NSWindow] = []
    private var screenNumbers: [NSNumber?] = [] // per window, for relayout
    private var tiles: [TileProcess] = []       // parallel to layers
    private var layers: [CALayer] = []
    private var timer: Timer?
    private var rotationTimer: Timer?
    private var rotationIndex = 0 // next tile to rotate, round-robin
    private var shmCounter = 0    // fresh shm name for every spawned helper
    private let rotationQueue = DispatchQueue(label: "tile-rotation")
    private var observer: NSObjectProtocol?

    /// Adapts a fixed rom/movie list to a cycling tile source, no rotation.
    public convenience init(pairs: [(rom: String, movie: String?)], columns: Int, rows: Int,
                            screens: [NSScreen]) throws {
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
            rotationInterval: nil, columns: columns, rows: rows, screens: screens)
    }

    /// tileSource is called once per tile at startup and once per rotation.
    /// With rotationInterval set, one tile is replaced every
    /// rotationInterval / tileCount seconds, round-robin, so tiles change on
    /// a stagger rather than all at once.
    public init(tileSource: @escaping () -> TileSpec, rotationInterval: TimeInterval?,
                columns: Int, rows: Int, screens: [NSScreen]) throws {
        guard columns > 0, rows > 0, !screens.isEmpty else {
            throw WallpaperError("need at least one rom, one screen, and a positive grid")
        }
        self.columns = columns
        self.rows = rows
        self.tileSource = tileSource

        helper = try Self.findHelper()

        // Spawn every helper first, then open their segments: startup
        // (ROM load, shm create) overlaps across processes.
        for screen in screens {
            let window = Self.makeDesktopWindow(frame: screen.frame)
            let content = NSView(frame: screen.frame)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = content

            for _ in 0..<(columns * rows) {
                tiles.append(try spawnTile(tileSource()))

                let layer = CALayer()
                layer.contentsGravity = .resizeAspect // letterbox 256x240 in the cell
                layer.magnificationFilter = .nearest
                content.layer?.addSublayer(layer)
                layers.append(layer)
            }

            windows.append(window)
            screenNumbers.append(
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            window.orderFront(nil)
        }
        layoutLayers()

        for tile in tiles where !tile.openSharedMemory() {
            Self.log("helper for \(tile.shmName) never published; tile stays black")
            tile.terminate()
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

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
    }

    public func shutdown() {
        timer?.invalidate()
        timer = nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
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
            startFrame: spec.startFrame)
    }

    /// Replace one tile, round-robin, without blocking the main thread:
    /// spawn the replacement, wait on a background queue until it is actually
    /// publishing frames (ROM load + optional fast-forward can take seconds),
    /// and only then — back on the main queue — terminate the old helper and
    /// swap the new one in. The layer keeps showing the old game until then.
    /// If the replacement never publishes, the old tile keeps running until
    /// the next rotation attempt.
    private func rotateNextTile() {
        guard !tiles.isEmpty else { return }
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
                self.tiles[index].terminate()
                self.tiles[index] = replacement
            }
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(msg)\n".utf8))
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (tile, layer) in zip(tiles, layers) {
            if layer.contents == nil || tile.frameCount != tile.lastFrameCount {
                if let image = tile.makeImage() { layer.contents = image }
            }
        }
        CATransaction.commit()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (windowIndex, window) in windows.enumerated() {
            guard let bounds = window.contentView?.bounds else { continue }
            let cellWidth = bounds.width / CGFloat(columns)
            let cellHeight = bounds.height / CGFloat(rows)
            let base = windowIndex * columns * rows
            for row in 0..<rows {
                for col in 0..<columns {
                    let index = base + row * columns + col
                    guard index < layers.count else { continue }
                    layers[index].frame = CGRect(
                        x: CGFloat(col) * cellWidth,
                        y: bounds.height - CGFloat(row + 1) * cellHeight,
                        width: cellWidth, height: cellHeight)
                }
            }
        }
        CATransaction.commit()
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
        }
        layoutLayers()
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
