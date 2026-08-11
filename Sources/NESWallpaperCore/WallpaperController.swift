import AppKit

public struct WallpaperError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Renders a columns x rows grid of NES tiles on a borderless window at
/// desktop level (behind icons) on each requested screen. Each tile is a
/// nes-helper child process read via shared memory.
public final class WallpaperController {
    private let columns: Int
    private let rows: Int
    private var windows: [NSWindow] = []
    private var screenNumbers: [NSNumber?] = [] // per window, for relayout
    private var tiles: [TileProcess] = []       // parallel to layers
    private var layers: [CALayer] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    public init(pairs: [(rom: String, movie: String?)], columns: Int, rows: Int,
                screens: [NSScreen]) throws {
        guard !pairs.isEmpty, columns > 0, rows > 0, !screens.isEmpty else {
            throw WallpaperError("need at least one rom, one screen, and a positive grid")
        }
        self.columns = columns
        self.rows = rows

        let helper = try Self.findHelper()

        // Spawn every helper first, then open their segments: startup
        // (ROM load, shm create) overlaps across processes.
        var tileIndex = 0
        for screen in screens {
            let window = Self.makeDesktopWindow(frame: screen.frame)
            let content = NSView(frame: screen.frame)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = content

            for _ in 0..<(columns * rows) {
                let pair = pairs[tileIndex % pairs.count]
                let shmName = "/nes.\(getpid()).\(tileIndex)"
                tiles.append(try TileProcess(
                    helper: helper, shmName: shmName, rom: pair.rom, movie: pair.movie))

                let layer = CALayer()
                layer.contentsGravity = .resizeAspect // letterbox 256x240 in the cell
                layer.magnificationFilter = .nearest
                content.layer?.addSublayer(layer)
                layers.append(layer)
                tileIndex += 1
            }

            windows.append(window)
            screenNumbers.append(
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            window.orderFront(nil)
        }
        layoutLayers()

        for tile in tiles where !tile.openSharedMemory() {
            FileHandle.standardError.write(
                Data("nes-wallpaper: helper for \(tile.shmName) never published; tile stays black\n".utf8))
            tile.terminate()
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    public func shutdown() {
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        for tile in tiles { tile.terminate() }
        tiles.removeAll()
        for window in windows { window.orderOut(nil) }
    }

    deinit { shutdown() }

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
