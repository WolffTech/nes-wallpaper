// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Keyboard layout for live play, remappable in Settings. The standard map
/// is arrows = D-pad, X = A, Z = B, Return = Start, Right Shift = Select;
/// Esc always ends the session and is never bindable.
public struct TakeoverKeymap: Equatable {
    /// keyCode → button. Modifier keys appear here too; they arrive as
    /// flagsChanged events and are resolved via modifierBinding(for:).
    public var bindings: [UInt16: NESButtons]

    /// Reserved session-end key; recording UIs must refuse it.
    public static let escapeKeyCode: UInt16 = 53

    /// The default layout. Keypad Enter (76) doubles as Start.
    public static let standard = TakeoverKeymap(bindings: [
        7: .a,      // X
        6: .b,      // Z
        36: .start, // Return
        76: .start, // keypad Enter
        60: .select, // Right Shift
        123: .left,
        124: .right,
        125: .down,
        126: .up,
    ])

    /// Modifier keyCodes and their device-specific NSEvent.ModifierFlags
    /// bits (the Carbon NX_DEVICE* masks), so left and right variants are
    /// distinct. Caps Lock (57) and Fn (63) are deliberately absent: they
    /// toggle or have no clean down/up pair, so they are not recordable.
    public static let modifierFlagBits: [UInt16: UInt] = [
        56: 0x02,   // Left Shift
        60: 0x04,   // Right Shift
        59: 0x01,   // Left Control
        62: 0x2000, // Right Control
        58: 0x20,   // Left Option
        61: 0x40,   // Right Option
        55: 0x08,   // Left Command
        54: 0x10,   // Right Command
    ]

    /// True for keyCodes that arrive as flagsChanged rather than
    /// keyDown/keyUp (and are therefore recordable modifier bindings).
    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierFlagBits[keyCode] != nil
    }

    public init(bindings: [UInt16: NESButtons]) {
        self.bindings = bindings
    }

    public func button(for keyCode: UInt16) -> NESButtons? {
        bindings[keyCode]
    }

    /// The bound button and device flag bit when keyCode is a bound
    /// modifier key; nil for unbound or non-modifier keyCodes.
    public func modifierBinding(for keyCode: UInt16) -> (NESButtons, UInt)? {
        guard let button = bindings[keyCode],
              let bit = Self.modifierFlagBits[keyCode] else { return nil }
        return (button, bit)
    }
}

// MARK: - UserDefaults serialization

extension TakeoverKeymap {
    /// Stable per-button names used as dictionary keys in UserDefaults.
    public static let buttonNames: [(name: String, button: NESButtons)] = [
        ("up", .up), ("down", .down), ("left", .left), ("right", .right),
        ("a", .a), ("b", .b), ("start", .start), ("select", .select),
    ]

    /// The key shown for each button of the standard map when a button has
    /// alternates (Start is Return; keypad Enter is a hidden extra).
    public static let standardPrimaryKeyCodes: [String: Int] = [
        "up": 126, "down": 125, "left": 123, "right": 124,
        "a": 7, "b": 6, "start": 36, "select": 60,
    ]

    /// Per-button overrides relative to `.standard`, the form saved to
    /// UserDefaults: unmodified buttons are omitted, a rebound button maps
    /// to its keyCode, a cleared button to -1.
    public var buttonAssignments: [String: Int] {
        var result: [String: Int] = [:]
        for (name, button) in Self.buttonNames {
            let keys = Set(bindings.filter { $0.value == button }.keys)
            let defaults = Set(Self.standard.bindings.filter { $0.value == button }.keys)
            guard keys != defaults else { continue }
            result[name] = keys.first.map(Int.init) ?? -1
        }
        return result
    }

    /// Build a map from per-button overrides merged over `.standard`: a
    /// button absent from the dict keeps all its default keys; a present
    /// button drops its defaults (including hidden alternates like keypad
    /// Enter for Start) in favor of the single custom key. A negative
    /// keyCode clears the button entirely ("None" mid-edit).
    public init(buttonAssignments: [String: Int]) {
        var merged = Self.standard.bindings
        for (name, button) in Self.buttonNames {
            guard let assigned = buttonAssignments[name] else { continue }
            merged = merged.filter { $0.value != button }
            if assigned >= 0, let keyCode = UInt16(exactly: assigned),
               keyCode != Self.escapeKeyCode {
                merged[keyCode] = button
            }
        }
        self.init(bindings: merged)
    }
}
