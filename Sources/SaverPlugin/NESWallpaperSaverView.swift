import ScreenSaver
import NESWallpaperCore

/// A tile slot whose frame file could not be mapped; renders as a black
/// cell, same as a dead tile does on the wallpaper.
private struct EmptyTile: TileFrameSource {
    var frameCount: UInt32 { 0 }
    func withFrontBuffer<R>(_ body: (UnsafeRawPointer, _ bytesPerRow: Int) -> R)
        -> (frameCount: UInt32, result: R)? { nil }
}

/// The screensaver half of the wallpaper: a thin read-only client of the
/// frame files the app's helpers are already writing. It spawns nothing and
/// composites the same grid with the same Metal renderer, inside the
/// sandboxed legacyScreenSaver host. Coordination with the app is entirely
/// file-based (see SharedFrames): the manifest tells us what to map, and our
/// heartbeat tells the app to keep emulating while the screen is locked.
@objc(NESWallpaperSaverView)
public final class NESWallpaperSaverView: ScreenSaverView {
    private var context: MetalContext?
    private var metalView: WallpaperMetalView?
    private var renderer: TileGridRenderer?
    private var tiles: [any TileFrameSource] = []
    private var tilePaths: [String] = []
    private var gridShape: (columns: Int, rows: Int, width: Int, height: Int)?
    /// Heartbeat + manifest polling; runs only between start/stopAnimation.
    private var pollTimer: Timer?
    private let statusLabel = NSTextField(labelWithString: "")

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        setupStatusLabel()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        setupStatusLabel()
    }

    // MARK: - Lifecycle

    public override func startAnimation() {
        super.startAnimation()
        reloadManifest()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTick()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        pollTimer?.invalidate()
        pollTimer = nil
        // Release the app immediately rather than waiting out the
        // heartbeat's freshness window.
        try? FileManager.default.removeItem(at: Self.heartbeatURL)
        // Sonoma+ is known to leave the host process (and sometimes the
        // saver instance) alive after dismissal, which would keep burning
        // GPU time. Exiting is the community workaround (see XScreenSaver
        // 6.08). The System Settings preview must not kill its host.
        if !isPreview { exit(0) }
    }

    public override func animateOneFrame() {
        if let renderer { renderer.draw(tiles: tiles, range: 0..<tiles.count) }
    }

    // MARK: - Heartbeat

    /// Inside the sandbox NSHomeDirectory() is the legacyScreenSaver
    /// container's Data directory — the one place we can write, and where
    /// the app looks (SharedFrames.appSideHeartbeatURL).
    private static let heartbeatURL =
        SharedFrames.heartbeatURL(home: URL(fileURLWithPath: NSHomeDirectory()))

    private func pollTick() {
        touchHeartbeat()
        reloadManifest()
    }

    private func touchHeartbeat() {
        // Occlusion-gated: if a zombie instance lingers after dismissal
        // (stopAnimation reportedly never fires on some macOS releases), it
        // must not hold the app's emulators awake forever.
        guard window?.occlusionState.contains(.visible) == true else { return }
        let url = Self.heartbeatURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // MARK: - Manifest / tile mapping

    private func reloadManifest() {
        guard let manifest = SharedFrames.readManifest(),
              kill(manifest.pid, 0) == 0 || errno != ESRCH else {
            // No wallpaper app behind the manifest (not running, or it
            // crashed and left a stale file): show why the screen is empty.
            tearDownRenderer()
            statusLabel.stringValue = "NES Wallpaper is not running"
            statusLabel.isHidden = false
            return
        }
        statusLabel.isHidden = true

        let shape = (manifest.columns, manifest.rows,
                     manifest.tileWidth, manifest.tileHeight)
        if renderer == nil || gridShape ?? (0, 0, 0, 0) != shape {
            rebuildRenderer(manifest: manifest)
        }
        guard let renderer else { return }

        // Remap tiles whose path changed (rotation), and keep retrying
        // slots that never mapped (helper still starting, or tile dead).
        for (index, path) in manifest.tiles.enumerated()
        where index < tiles.count {
            let mapped = tiles[index] is MappedTile
            guard !mapped || tilePaths[index] != path else { continue }
            tiles[index] = MappedTile(path: path) ?? EmptyTile()
            tilePaths[index] = path
            // A fresh mapping restarts frame_count; never trust a
            // coincidental match with the previous occupant.
            renderer.invalidateTile(index)
        }
    }

    private func rebuildRenderer(manifest: SharedFrames.Manifest) {
        tearDownRenderer()
        do {
            let context = try self.context ?? MetalContext()
            self.context = context
            let view = WallpaperMetalView(frame: bounds, device: context.device)
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: statusLabel)
            renderer = try TileGridRenderer(
                context: context, view: view,
                columns: manifest.columns, rows: manifest.rows,
                tileWidth: manifest.tileWidth, tileHeight: manifest.tileHeight)
            metalView = view
            gridShape = (manifest.columns, manifest.rows,
                         manifest.tileWidth, manifest.tileHeight)
            let slots = manifest.columns * manifest.rows
            tiles = Array(repeating: EmptyTile(), count: slots)
            tilePaths = Array(repeating: "", count: slots)
        } catch {
            tearDownRenderer()
            statusLabel.stringValue = "NES Wallpaper: no Metal device"
            statusLabel.isHidden = false
        }
    }

    private func tearDownRenderer() {
        metalView?.removeFromSuperview()
        metalView = nil
        renderer = nil
        gridShape = nil
        tiles = []
        tilePaths = []
    }

    // MARK: - Fallback

    private func setupStatusLabel() {
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: isPreview ? 11 : 24, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        statusLabel.isHidden = true
    }

    public override func draw(_ rect: NSRect) {
        // Black behind the Metal view (and alone, when there is no grid).
        NSColor.black.setFill()
        rect.fill()
    }
}
