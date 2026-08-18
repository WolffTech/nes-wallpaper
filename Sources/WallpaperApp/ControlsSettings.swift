// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon.HIToolbox
import SwiftUI
import NESWallpaperCore

/// Backing model for the Controls tab. Unlike SettingsModel, edits apply
/// immediately: each successful capture saves to UserDefaults and pushes the
/// new keymap to the running controller — a remap needs no restart, and the
/// shared Apply button's restart would kill running games for an input tweak.
final class ControlsModel: ObservableObject {
    /// Button name → keyCode override; absent = default, -1 = cleared.
    @Published var assignments: [String: Int] = [:]
    /// Button name currently armed for key capture, at most one.
    @Published var recording: String?
    /// Brief footer message after a rejected capture.
    @Published var message: String?
    /// Global takeover shortcut and its independent capture state.
    @Published var takeoverShortcut: GlobalShortcut?
    @Published var recordingShortcut = false
    @Published var shortcutMessage: String?
    /// Fill the takeover display with the played tile during live play.
    @Published var fullscreenTakeover = false

    var onChanged: (() -> Void)?
    /// Returns a user-facing registration error, or nil after saving.
    var onShortcutChanged: ((GlobalShortcut?) -> String?)?
    var onShortcutRecordingChanged: ((Bool) -> Void)?

    init() {
        takeoverShortcut = WallpaperSettings.load().takeoverShortcut
        fullscreenTakeover = WallpaperSettings.load().fullscreenTakeover
    }

    func load() {
        if recordingShortcut { onShortcutRecordingChanged?(false) }
        assignments = WallpaperSettings.load().takeoverControls
        takeoverShortcut = WallpaperSettings.load().takeoverShortcut
        fullscreenTakeover = WallpaperSettings.load().fullscreenTakeover
        recording = nil
        recordingShortcut = false
        message = nil
        shortcutMessage = nil
    }

    private func save() {
        var settings = WallpaperSettings.load()
        settings.takeoverControls = assignments
        settings.save()
        onChanged?()
    }

    func setFullscreenTakeover(_ enabled: Bool) {
        fullscreenTakeover = enabled
        var settings = WallpaperSettings.load()
        settings.fullscreenTakeover = enabled
        settings.save()
        onChanged?()
    }

    /// The key currently bound to a button, nil when cleared ("None").
    func keyCode(for button: String) -> Int? {
        if let assigned = assignments[button] {
            return assigned >= 0 ? assigned : nil
        }
        return TakeoverKeymap.standardPrimaryKeyCodes[button]
    }

    func displayName(for button: String) -> String {
        guard let code = keyCode(for: button),
              let keyCode = UInt16(exactly: code) else { return "None" }
        return KeyName.string(for: keyCode)
    }

    func record(_ button: String) {
        cancelShortcutRecording()
        recording = button
        message = nil
    }

    func cancelRecording() {
        recording = nil
    }

    var isRecording: Bool { recording != nil || recordingShortcut }

    func recordShortcut() {
        recording = nil
        recordingShortcut = true
        shortcutMessage = nil
        onShortcutRecordingChanged?(true)
    }

    func cancelShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        onShortcutRecordingChanged?(false)
    }

    func cancelAllRecording() {
        cancelRecording()
        cancelShortcutRecording()
    }

    func assignShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard recordingShortcut else { return }
        guard let shortcut = GlobalShortcut(keyCode: keyCode, modifiers: modifiers) else {
            shortcutMessage = "Use a key with Control, Option, or Command."
            return
        }
        recordingShortcut = false
        if let error = onShortcutChanged?(shortcut) {
            shortcutMessage = error
        } else {
            takeoverShortcut = shortcut
            shortcutMessage = nil
        }
        onShortcutRecordingChanged?(false)
    }

    func clearShortcut() {
        cancelShortcutRecording()
        if let error = onShortcutChanged?(nil) {
            shortcutMessage = error
        } else {
            takeoverShortcut = nil
            shortcutMessage = nil
        }
    }

    func restoreDefaultShortcut() {
        cancelShortcutRecording()
        let shortcut = GlobalShortcut.defaultTakeover
        if let error = onShortcutChanged?(shortcut) {
            shortcutMessage = error
        } else {
            takeoverShortcut = shortcut
            shortcutMessage = nil
        }
    }

    /// Complete an armed capture: bind the key to the recorded button
    /// (stealing it from any other button), save, and disarm.
    func assign(keyCode: UInt16) {
        guard let button = recording else { return }
        recording = nil
        guard keyCode != TakeoverKeymap.escapeKeyCode else {
            message = "Esc always ends a live session and can\u{2019}t be reassigned."
            return
        }
        guard Self.recordable(keyCode) else {
            message = "That key can\u{2019}t be assigned."
            return
        }
        assignments = Self.assigning(keyCode: Int(keyCode), to: button, in: assignments)
        message = nil
        save()
    }

    func restoreDefaults() {
        recording = nil
        message = nil
        assignments = [:]
        save()
    }

    /// Caps Lock toggles and Fn has no clean down/up pair; every other
    /// modifier and any character key is fair game.
    static func recordable(_ keyCode: UInt16) -> Bool {
        keyCode != 57 && keyCode != 63
    }

    /// Pure assignment transform: bind keyCode to button; a key already
    /// bound to another button (custom or default) is stolen and the loser
    /// cleared to -1 ("None") — standard game-settings behavior.
    static func assigning(keyCode: Int, to button: String,
                          in assignments: [String: Int]) -> [String: Int] {
        var result = assignments
        let current = TakeoverKeymap(buttonAssignments: assignments)
        if let code = UInt16(exactly: keyCode),
           let owner = current.button(for: code),
           let ownerName = TakeoverKeymap.buttonNames
               .first(where: { $0.button == owner })?.name,
           ownerName != button {
            result[ownerName] = -1
        }
        result[button] = keyCode
        return result
    }
}

/// Human-readable name for a virtual keyCode: a fixed table for keys that
/// produce no useful character (arrows, modifiers, keypad), the current
/// keyboard layout via UCKeyTranslate for character keys.
enum KeyName {
    static func string(for keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        if let name = layoutName(for: keyCode) { return name }
        return "Key \(keyCode)"
    }

    static let specialNames: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        76: "Keypad Enter", 117: "Forward Delete", 114: "Help",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        56: "Left Shift", 60: "Right Shift",
        59: "Left Control", 62: "Right Control",
        58: "Left Option", 61: "Right Option",
        55: "Left Command", 54: "Right Command",
        57: "Caps Lock", 63: "Fn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        71: "Keypad Clear", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +",
        75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9",
    ]

    private static func layoutName(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let layoutData = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData)
            .takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self)
                .baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let name = String(utf16CodeUnits: chars, count: length)
                .uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }
}

/// Invisible responder-chain key capture for the Controls tab. Events are
/// consumed in keyDown/flagsChanged overrides, never with an NSEvent
/// monitor: NSWindow's default keyDown path beeps for every press it
/// considers unhandled (the WallpaperWindow lesson).
struct KeyCaptureView: NSViewRepresentable {
    @ObservedObject var model: ControlsModel

    final class CaptureView: NSView {
        weak var model: ControlsModel?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let model, model.isRecording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == TakeoverKeymap.escapeKeyCode {
                model.cancelAllRecording()
            } else if model.recordingShortcut {
                model.assignShortcut(
                    keyCode: event.keyCode, modifiers: event.modifierFlags)
            } else {
                model.assign(keyCode: event.keyCode)
            }
        }

        // Cmd-combos must assign the bare key, not route to the menu bar,
        // while recording (a held Cmd is ignored; only a *pressed* Cmd key
        // itself records, via flagsChanged).
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let model, model.isRecording,
                  event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            guard let model, model.isRecording else {
                super.flagsChanged(with: event)
                return
            }
            // A global shortcut is a chord; wait for its non-modifier key.
            if model.recordingShortcut { return }
            if let bit = TakeoverKeymap.modifierFlagBits[event.keyCode] {
                // Assign on press only; the release after assigning (or of
                // an unrelated held modifier) is ignored.
                if event.modifierFlags.rawValue & bit != 0 {
                    model.assign(keyCode: event.keyCode)
                }
            } else if !ControlsModel.recordable(event.keyCode) {
                model.assign(keyCode: event.keyCode) // rejects with message
            }
        }

        // Clicking anywhere else (or Tab moving focus) disarms recording.
        override func resignFirstResponder() -> Bool {
            if let model, model.isRecording {
                DispatchQueue.main.async { model.cancelAllRecording() }
            }
            return super.resignFirstResponder()
        }
    }

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.model = model
        guard let window = view.window else { return }
        if model.isRecording {
            if window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        } else if window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
    }
}

/// The Controls settings pane: one row per NES control, click to arm
/// recording, press a key to bind it.
struct ControlsPane: View {
    @ObservedObject var model: ControlsModel

    private static let dPad = [("Up", "up"), ("Down", "down"),
                               ("Left", "left"), ("Right", "right")]
    private static let pad = [("A", "a"), ("B", "b"),
                              ("Start", "start"), ("Select", "select")]

    var body: some View {
        Form {
            Section {
                LabeledContent("Take Over Game") {
                    HStack {
                        Button {
                            model.recordShortcut()
                        } label: {
                            Text(model.recordingShortcut
                                 ? "Press shortcut\u{2026}"
                                 : model.takeoverShortcut?.displayName ?? "None")
                                .frame(minWidth: 100)
                        }
                        Button("Clear") { model.clearShortcut() }
                            .disabled(model.takeoverShortcut == nil)
                    }
                }
                LabeledContent("Default") {
                    Button("Restore \(GlobalShortcut.defaultTakeover.displayName)") {
                        model.restoreDefaultShortcut()
                    }
                }
            } header: {
                Text("Global Shortcut")
            } footer: {
                shortcutFooter
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("D-Pad") {
                ForEach(Self.dPad, id: \.1) { row(label: $0.0, button: $0.1) }
            }
            Section("Buttons") {
                ForEach(Self.pad, id: \.1) { row(label: $0.0, button: $0.1) }
            }
            Section {
                LabeledContent("Defaults") {
                    Button("Restore Defaults") { model.restoreDefaults() }
                }
            } footer: {
                footerText
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .background(KeyCaptureView(model: model))
    }

    private var shortcutFooter: Text {
        if let message = model.shortcutMessage {
            return Text(message).foregroundStyle(.red)
        }
        return Text("Works from any app. Press Esc to cancel recording. Changes take effect immediately.")
    }

    private var footerText: Text {
        if let message = model.message {
            return Text(message).foregroundStyle(.red)
        }
        return Text("Click a control, then press the key to assign. Esc always ends a live session and can\u{2019}t be reassigned. Changes take effect immediately for the next takeover.")
    }

    private func row(label: String, button: String) -> some View {
        LabeledContent(label) {
            Button {
                model.record(button)
            } label: {
                Text(model.recording == button
                     ? "Press a key\u{2026}"
                     : model.displayName(for: button))
                    .frame(minWidth: 100)
            }
        }
    }
}
