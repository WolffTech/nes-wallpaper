import AppKit

/// Maps a point in a wallpaper window to the tile whose grid cell contains
/// it. Points are in AppKit window/view coordinates (origin bottom-left);
/// tiles are row-major from the top-left, matching TileGridRenderer. The
/// whole cell counts, including a tile's letterbox margins.
enum TileGridHitTest {
    static func tileIndex(at point: CGPoint, in size: CGSize,
                          columns: Int, rows: Int) -> Int? {
        guard size.width > 0, size.height > 0, columns > 0, rows > 0 else { return nil }
        let column = Int(floor(point.x / size.width * CGFloat(columns)))
        let rowFromBottom = Int(floor(point.y / size.height * CGFloat(rows)))
        guard (0..<columns).contains(column), (0..<rows).contains(rowFromBottom) else {
            return nil
        }
        return (rows - 1 - rowFromBottom) * columns + column
    }
}

/// "Click a game to play" mode: raises every wallpaper window above the
/// desktop icons, spotlights the tile under the mouse, and reports the
/// clicked tile. Esc, focus loss, or the menu cancel it. The controller
/// owns the mode's lifecycle and restores renderer emphasis after stop().
final class TileSelectionMode {
    private struct SavedWindow {
        let window: WallpaperWindow
        let level: NSWindow.Level
        let ignoresMouse: Bool
    }

    private let windows: [WallpaperWindow]
    private let columns: Int
    private let rows: Int
    private let onHover: (Int?) -> Void
    private let onPick: (Int) -> Void
    private let onCancel: () -> Void

    private var saved: [SavedWindow] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var hoverTimer: Timer?
    private var lastHover: Int??

    init(windows: [WallpaperWindow], columns: Int, rows: Int,
         onHover: @escaping (Int?) -> Void,
         onPick: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        self.windows = windows
        self.columns = columns
        self.rows = rows
        self.onHover = onHover
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func start() {
        for window in windows {
            saved.append(SavedWindow(window: window, level: window.level,
                                     ignoresMouse: window.ignoresMouseEvents))
            window.allowKey = true
            window.level = .normal
            window.ignoresMouseEvents = false
        }
        NSApp.activate(ignoringOtherApps: true)
        // One key window is enough for Esc; clicks work on any display.
        (windowUnder(NSEvent.mouseLocation) ?? windows.first)?
            .makeKeyAndOrderFront(nil)

        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]) { [weak self] event in
            self?.handleMouseDown(event) ?? event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        } as Any)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil,
            queue: .main) { [weak self] _ in self?.onCancel() })

        // Hover tracking polls the mouse instead of routing mouseMoved
        // events: it survives display crossings and menu tracking for the
        // price of a 30 Hz timer that lives only while selecting.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        updateHover()
    }

    func stop() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for entry in saved {
            entry.window.level = entry.level
            entry.window.ignoresMouseEvents = entry.ignoresMouse
            entry.window.allowKey = false
        }
        saved.removeAll()
    }

    private func windowUnder(_ screenPoint: NSPoint) -> WallpaperWindow? {
        windows.first { $0.frame.contains(screenPoint) }
    }

    private func updateHover() {
        var tile: Int?
        let mouse = NSEvent.mouseLocation
        if let window = windowUnder(mouse) {
            tile = TileGridHitTest.tileIndex(
                at: CGPoint(x: mouse.x - window.frame.minX,
                            y: mouse.y - window.frame.minY),
                in: window.frame.size, columns: columns, rows: rows)
        }
        if lastHover != .some(tile) {
            lastHover = .some(tile)
            onHover(tile)
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window as? WallpaperWindow,
              windows.contains(where: { $0 === window }) else { return event }
        if let tile = TileGridHitTest.tileIndex(
            at: event.locationInWindow, in: window.frame.size,
            columns: columns, rows: rows) {
            onPick(tile)
        }
        return nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == TakeoverKeymap.escapeKeyCode {
            onCancel()
            return nil
        }
        // Swallow stray keys aimed at wallpaper windows (no responder
        // handles them; they would just beep).
        if let window = event.window as? WallpaperWindow,
           windows.contains(where: { $0 === window }) {
            return nil
        }
        return event
    }
}
