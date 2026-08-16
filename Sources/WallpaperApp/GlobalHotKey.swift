// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon.HIToolbox
import NESWallpaperCore

/// A layout-aware key plus the device-independent modifiers used for a
/// system-wide shortcut. Virtual key codes match the rest of the app's input
/// settings and keep the physical shortcut stable when the keyboard layout
/// changes.
struct GlobalShortcut: Equatable {
    static let defaultTakeover = GlobalShortcut(
        keyCode: 5, // G
        modifiers: [.control, .option])!

    private static let allowedModifiers: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command,
    ]
    private static let requiredModifiers: NSEvent.ModifierFlags = [
        .control, .option, .command,
    ]

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let normalized = modifiers.intersection(Self.allowedModifiers)
        guard !normalized.intersection(Self.requiredModifiers).isEmpty,
              keyCode != TakeoverKeymap.escapeKeyCode,
              !TakeoverKeymap.isModifierKeyCode(keyCode),
              keyCode != 57, keyCode != 63 else { return nil }
        self.keyCode = keyCode
        self.modifiers = normalized
    }

    init?(storedValue: [String: Any]) {
        guard let keyCodeValue = storedValue["keyCode"] as? NSNumber,
              let keyCode = UInt16(exactly: keyCodeValue.intValue),
              let modifierValue = storedValue["modifiers"] as? NSNumber else { return nil }
        self.init(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifierValue.uint64Value)))
    }

    var storedValue: [String: Int] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)]
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + KeyName.string(for: keyCode)
    }

    fileprivate var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

enum GlobalHotKeyError: LocalizedError, Equatable {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandler(let status):
            return "Couldn\u{2019}t initialize global shortcuts (error \(status))."
        case .registration(let status) where status == eventHotKeyExistsErr:
            return "That shortcut is already in use."
        case .registration(let status):
            return "Couldn\u{2019}t register that shortcut (error \(status))."
        }
    }
}

/// Owns the Carbon hot-key event handler and one exclusive registration.
/// Carbon's hot-key service works while another app is active without asking
/// for Accessibility access, unlike observing all global keyboard events.
final class GlobalHotKey {
    private static let signature: OSType = 0x4E_45_53_57 // "NESW"
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private(set) var shortcut: GlobalShortcut?
    private let action: () -> Void

    init(action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                var actualSize = 0
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, &actualSize, &hotKeyID)
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKey.signature,
                      hotKeyID.id == GlobalHotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<GlobalHotKey>.fromOpaque(userData)
                    .takeUnretainedValue().action()
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { throw GlobalHotKeyError.eventHandler(status) }
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Replace the current shortcut. If registration fails, the previous
    /// shortcut is restored so a rejected edit never silently disables it.
    func setShortcut(_ newShortcut: GlobalShortcut?) throws {
        guard newShortcut != shortcut else { return }
        let previous = shortcut
        unregister()
        guard let newShortcut else { return }
        do {
            try register(newShortcut)
        } catch {
            if let previous { try? register(previous) }
            throw error
        }
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, identifier,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw GlobalHotKeyError.registration(status)
        }
        hotKey = reference
        self.shortcut = shortcut
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        shortcut = nil
    }
}
