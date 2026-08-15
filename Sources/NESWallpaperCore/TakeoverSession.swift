// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// Borderless desktop-level wallpaper window. Refuses key status except
/// during a takeover session or tile selection, when it must receive the
/// keyboard.
final class WallpaperWindow: NSWindow {
    var allowKey = false

    /// Key events are consumed here, in the responder chain, rather than
    /// swallowed by an event monitor: NSWindow's default keyDown path plays
    /// the system alert for every press it considers unhandled, monitor or
    /// not. Return true when the event was consumed.
    var keyEventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { allowKey }

    override func keyDown(with event: NSEvent) {
        if keyEventHandler?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if keyEventHandler?(event) != true { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if keyEventHandler?(event) != true { super.flagsChanged(with: event) }
    }
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
    /// Fixed for the session's lifetime; a remap in Settings applies to
    /// the next takeover, not this one.
    private let keymap: TakeoverKeymap
    private let savedLevel: NSWindow.Level
    private let savedIgnoresMouse: Bool
    private var observers: [NSObjectProtocol] = []
    private var heldButtons: NESButtons = []
    /// Asks the controller to tear the session down (idempotent); fired by
    /// Esc, the window resigning key, or the app resigning active.
    private let requestEnd: () -> Void

    init(tileIndex: Int, tile: TileProcess, window: WallpaperWindow,
         keymap: TakeoverKeymap = .standard,
         requestEnd: @escaping () -> Void) {
        self.tileIndex = tileIndex
        self.tile = tile
        self.window = window
        self.keymap = keymap
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
        window.keyEventHandler = { [weak self] event in
            self?.handle(event) ?? false
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
        window.keyEventHandler = nil
        tile.sendInput([])
        tile.endTakeover() // a looped movie restarts from frame 0
        window.level = savedLevel
        window.ignoresMouseEvents = savedIgnoresMouse
        window.allowKey = false
        // Hand focus back to whichever app had it; no-op when the session
        // ended because another app activated.
        NSApp.deactivate()
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown where event.keyCode == TakeoverKeymap.escapeKeyCode:
            requestEnd()
            return true
        case .keyDown, .keyUp:
            if let button = keymap.button(for: event.keyCode) {
                // Held buttons are level-based from keyDown/keyUp pairs;
                // auto-repeats are consumed without resending.
                if event.type == .keyUp {
                    heldButtons.remove(button)
                    tile.sendInput(heldButtons)
                } else if !event.isARepeat {
                    heldButtons.insert(button)
                    tile.sendInput(heldButtons)
                }
            }
            // The game owns the keyboard while playing: consume unmapped
            // keys too instead of letting them fall through and beep.
            return true
        case .flagsChanged:
            guard let (button, flagBit) = keymap.modifierBinding(for: event.keyCode)
            else { return false }
            // Device-specific flag bits distinguish left/right variants;
            // pressed state is level-based like keyDown/keyUp.
            if event.modifierFlags.rawValue & flagBit != 0 {
                heldButtons.insert(button)
            } else {
                heldButtons.remove(button)
            }
            tile.sendInput(heldButtons)
            return true
        default:
            return false
        }
    }
}
