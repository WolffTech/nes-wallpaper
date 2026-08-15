// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import XCTest
@testable import NESWallpaperCore

final class TakeoverKeymapTests: XCTestCase {
    func testStandardLayout() {
        let map = TakeoverKeymap.standard
        XCTAssertEqual(map.button(for: 7), .a)        // X
        XCTAssertEqual(map.button(for: 6), .b)        // Z
        XCTAssertEqual(map.button(for: 36), .start)   // Return
        XCTAssertEqual(map.button(for: 76), .start)   // keypad Enter
        XCTAssertEqual(map.button(for: 60), .select)  // Right Shift
        XCTAssertEqual(map.button(for: 123), .left)
        XCTAssertEqual(map.button(for: 124), .right)
        XCTAssertEqual(map.button(for: 125), .down)
        XCTAssertEqual(map.button(for: 126), .up)
    }

    func testEscapeIsNeverBound() {
        XCTAssertNil(TakeoverKeymap.standard.button(for: TakeoverKeymap.escapeKeyCode))
        // Even a hostile UserDefaults dict cannot bind Esc.
        let map = TakeoverKeymap(buttonAssignments: ["a": Int(TakeoverKeymap.escapeKeyCode)])
        XCTAssertNil(map.button(for: TakeoverKeymap.escapeKeyCode))
        XCTAssertFalse(map.bindings.values.contains(.a))
    }

    func testEmptyAssignmentsAreTheStandardMap() {
        XCTAssertEqual(TakeoverKeymap(buttonAssignments: [:]), .standard)
        XCTAssertEqual(TakeoverKeymap.standard.buttonAssignments, [:])
    }

    func testPartialAssignmentsMergeOverDefaults() {
        let map = TakeoverKeymap(buttonAssignments: ["a": 49]) // Space
        XCTAssertEqual(map.button(for: 49), .a)
        XCTAssertNil(map.button(for: 7)) // old A key released
        // Everything else keeps its default.
        XCTAssertEqual(map.button(for: 6), .b)
        XCTAssertEqual(map.button(for: 126), .up)
        XCTAssertEqual(map.modifierBinding(for: 60)?.0, .select)
    }

    func testCustomStartDropsKeypadEnterAlternate() {
        let map = TakeoverKeymap(buttonAssignments: ["start": 48]) // Tab
        XCTAssertEqual(map.button(for: 48), .start)
        XCTAssertNil(map.button(for: 36))
        XCTAssertNil(map.button(for: 76))
    }

    func testClearedButtonHasNoKey() {
        let map = TakeoverKeymap(buttonAssignments: ["b": -1])
        XCTAssertFalse(map.bindings.values.contains(.b))
        XCTAssertEqual(map.buttonAssignments, ["b": -1])
    }

    func testAssignmentsRoundTrip() {
        let assignments = ["a": 49, "select": 55, "up": -1] // Space, Left Cmd, cleared
        let map = TakeoverKeymap(buttonAssignments: assignments)
        XCTAssertEqual(map.buttonAssignments, assignments)
        XCTAssertEqual(TakeoverKeymap(buttonAssignments: map.buttonAssignments), map)
    }

    func testModifierClassification() {
        // Right Shift is a modifier with the device-specific flag bit …
        XCTAssertTrue(TakeoverKeymap.isModifierKeyCode(60))
        let binding = TakeoverKeymap.standard.modifierBinding(for: 60)
        XCTAssertEqual(binding?.0, .select)
        XCTAssertEqual(binding?.1, 0x04)
        // … X is not, and an unbound modifier resolves to nothing.
        XCTAssertFalse(TakeoverKeymap.isModifierKeyCode(7))
        XCTAssertNil(TakeoverKeymap.standard.modifierBinding(for: 7))
        XCTAssertNil(TakeoverKeymap.standard.modifierBinding(for: 55))
        // Caps Lock and Fn are not recordable modifiers.
        XCTAssertFalse(TakeoverKeymap.isModifierKeyCode(57))
        XCTAssertFalse(TakeoverKeymap.isModifierKeyCode(63))
    }

    func testDeviceFlagBits() {
        // The Carbon NX_DEVICE* bits have no public constants; pin the
        // documented values and the properties the session relies on:
        // distinct per key, and outside the device-independent masks so
        // they never collide with NSEvent.ModifierFlags checks.
        let expected: [UInt16: UInt] = [
            56: 0x02, 60: 0x04,     // Shift L/R
            59: 0x01, 62: 0x2000,   // Control L/R
            58: 0x20, 61: 0x40,     // Option L/R
            55: 0x08, 54: 0x10,     // Command L/R
        ]
        XCTAssertEqual(TakeoverKeymap.modifierFlagBits, expected)
        for bit in expected.values {
            XCTAssertEqual(
                bit & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue, 0)
        }
        let bits = expected.values
        XCTAssertEqual(Set(bits).count, bits.count, "device bits must be distinct")
    }
}
