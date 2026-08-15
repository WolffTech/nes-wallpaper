import AppKit

/// Borderless desktop-level wallpaper window. Refuses key status except
/// during a takeover session, when it must receive the keyboard.
final class WallpaperWindow: NSWindow {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
}

/// Keyboard layout for live play: arrows = D-pad, X = A, Z = B,
/// Return = Start, Right Shift = Select, Esc ends the session.
enum TakeoverKeymap {
    static let escapeKeyCode: UInt16 = 53
    static let rightShiftKeyCode: UInt16 = 60

    private static let buttons: [UInt16: NESButtons] = [
        7: .a,      // X
        6: .b,      // Z
        36: .start, // Return
        76: .start, // keypad Enter
        123: .left,
        124: .right,
        125: .down,
        126: .up,
    ]

    static func button(for keyCode: UInt16) -> NESButtons? { buttons[keyCode] }
}

/// One live-play session on a wallpaper tile: raises one display's wallpaper
/// window above the desktop icons, makes it key to capture the keyboard, and
/// streams held-button state to the tile's helper on change. stop() restores
/// the window and hands playback back to the helper; the controller owns
/// when sessions start and end (see WallpaperController.beginTakeover).
final class TakeoverSession {
    let tileIndex: Int
    let window: WallpaperWindow

    private let tile: TileProcess
    private let savedLevel: NSWindow.Level
    private let savedIgnoresMouse: Bool
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var heldButtons: NESButtons = []
    /// Asks the controller to tear the session down (idempotent); fired by
    /// Esc, the window resigning key, or the app resigning active.
    private let requestEnd: () -> Void

    init(tileIndex: Int, tile: TileProcess, window: WallpaperWindow,
         requestEnd: @escaping () -> Void) {
        self.tileIndex = tileIndex
        self.tile = tile
        self.window = window
        self.savedLevel = window.level
        self.savedIgnoresMouse = window.ignoresMouseEvents
        self.requestEnd = requestEnd
    }

    func start() {
        tile.beginTakeover()
        window.allowKey = true
        // Above the desktop icons so the window can become key and clicks
        // land on the game rather than on Finder; restored on stop().
        window.level = .normal
        window.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        // Focus moving anywhere else ends the session rather than leaving a
        // raised wallpaper window that no longer hears the keyboard.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window,
            queue: .main) { [weak self] _ in self?.requestEnd() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil,
            queue: .main) { [weak self] _ in self?.requestEnd() })
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tile.sendInput([])
        tile.endTakeover() // a looped movie restarts from frame 0
        window.level = savedLevel
        window.ignoresMouseEvents = savedIgnoresMouse
        window.allowKey = false
        // Hand focus back to whichever app had it; no-op when the session
        // ended because another app activated.
        NSApp.deactivate()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Only capture keys aimed at the raised wallpaper window; the app's
        // regular windows (Settings, browser) keep normal key handling.
        guard event.window === window else { return event }
        switch event.type {
        case .keyDown where event.keyCode == TakeoverKeymap.escapeKeyCode:
            requestEnd()
            return nil
        case .keyUp where event.keyCode == TakeoverKeymap.escapeKeyCode:
            return nil
        case .keyDown, .keyUp:
            guard let button = TakeoverKeymap.button(for: event.keyCode) else {
                return event
            }
            // Held buttons are level-based from keyDown/keyUp pairs; auto-
            // repeats are swallowed without resending.
            if event.type == .keyUp {
                heldButtons.remove(button)
                tile.sendInput(heldButtons)
            } else if !event.isARepeat {
                heldButtons.insert(button)
                tile.sendInput(heldButtons)
            }
            return nil
        case .flagsChanged where event.keyCode == TakeoverKeymap.rightShiftKeyCode:
            if event.modifierFlags.contains(.shift) {
                heldButtons.insert(.select)
            } else {
                heldButtons.remove(.select)
            }
            tile.sendInput(heldButtons)
            return nil
        default:
            return event
        }
    }
}
