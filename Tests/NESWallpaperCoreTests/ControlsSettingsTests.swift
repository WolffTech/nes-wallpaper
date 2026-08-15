// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import nes_wallpaper
@testable import NESWallpaperCore

final class ControlsModelStealTests: XCTestCase {
    func testAssignToFreeKeyLeavesOthersAlone() {
        let result = ControlsModel.assigning(keyCode: 49, to: "a", in: [:]) // Space
        XCTAssertEqual(result, ["a": 49])
    }

    func testAssignStealsFromDefaultBinding() {
        // Z is B's default; giving it to A must clear B to "None".
        let result = ControlsModel.assigning(keyCode: 6, to: "a", in: [:])
        XCTAssertEqual(result, ["a": 6, "b": -1])
    }

    func testAssignStealsFromCustomBinding() {
        let result = ControlsModel.assigning(keyCode: 49, to: "b", in: ["a": 49])
        XCTAssertEqual(result, ["b": 49, "a": -1])
    }

    func testAssignStealsHiddenStartAlternate() {
        // Keypad Enter is Start's hidden alternate while Start is
        // unmodified; binding it elsewhere still steals from Start.
        let result = ControlsModel.assigning(keyCode: 76, to: "select", in: [:])
        XCTAssertEqual(result, ["select": 76, "start": -1])
    }

    func testReassignSameButtonDoesNotSelfSteal() {
        let result = ControlsModel.assigning(keyCode: 7, to: "a", in: [:])
        XCTAssertEqual(result, ["a": 7])
    }

    func testStolenKeyRoundTripsThroughKeymap() {
        let assignments = ControlsModel.assigning(keyCode: 6, to: "a", in: [:])
        let map = TakeoverKeymap(buttonAssignments: assignments)
        XCTAssertEqual(map.button(for: 6), .a)
        XCTAssertFalse(map.bindings.values.contains(.b))
    }

    func testEscCapsLockAndFnAreNotRecordable() {
        XCTAssertTrue(ControlsModel.recordable(6))
        XCTAssertTrue(ControlsModel.recordable(60)) // Right Shift is fine
        XCTAssertFalse(ControlsModel.recordable(57)) // Caps Lock
        XCTAssertFalse(ControlsModel.recordable(63)) // Fn
    }
}

final class KeyNameTests: XCTestCase {
    func testFixedTableSpecials() {
        XCTAssertEqual(KeyName.string(for: 36), "Return")
        XCTAssertEqual(KeyName.string(for: 49), "Space")
        XCTAssertEqual(KeyName.string(for: 76), "Keypad Enter")
        XCTAssertEqual(KeyName.string(for: 123), "\u{2190}")
        XCTAssertEqual(KeyName.string(for: 126), "\u{2191}")
        XCTAssertEqual(KeyName.string(for: 60), "Right Shift")
        XCTAssertEqual(KeyName.string(for: 55), "Left Command")
    }

    func testEveryModifierAndDefaultKeyHasAName() {
        for keyCode in TakeoverKeymap.modifierFlagBits.keys {
            XCTAssertNotNil(KeyName.specialNames[keyCode], "keyCode \(keyCode)")
        }
        for keyCode in TakeoverKeymap.standard.bindings.keys {
            XCTAssertFalse(KeyName.string(for: keyCode).hasPrefix("Key "),
                           "keyCode \(keyCode)")
        }
    }

    func testUnknownKeyCodeFallsBack() {
        XCTAssertEqual(KeyName.string(for: 999), "Key 999")
    }
}
