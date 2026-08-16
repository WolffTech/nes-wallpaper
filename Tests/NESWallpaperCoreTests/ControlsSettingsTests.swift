// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
import AppKit
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

final class GlobalShortcutTests: XCTestCase {
    func testDefaultShortcutIsControlOptionG() {
        XCTAssertEqual(GlobalShortcut.defaultTakeover.keyCode, 5)
        XCTAssertEqual(GlobalShortcut.defaultTakeover.modifiers, [.control, .option])
        XCTAssertEqual(GlobalShortcut.defaultTakeover.displayName, "⌃⌥G")
    }

    func testRequiresControlOptionOrCommand() {
        XCTAssertNil(GlobalShortcut(keyCode: 5, modifiers: []))
        XCTAssertNil(GlobalShortcut(keyCode: 5, modifiers: [.shift]))
        XCTAssertNotNil(GlobalShortcut(keyCode: 5, modifiers: [.control]))
        XCTAssertNotNil(GlobalShortcut(keyCode: 5, modifiers: [.option]))
        XCTAssertNotNil(GlobalShortcut(keyCode: 5, modifiers: [.command]))
    }

    func testRejectsEscapeAndModifierKeys() {
        XCTAssertNil(GlobalShortcut(keyCode: 53, modifiers: [.command]))
        XCTAssertNil(GlobalShortcut(keyCode: 55, modifiers: [.option]))
        XCTAssertNil(GlobalShortcut(keyCode: 57, modifiers: [.control]))
        XCTAssertNil(GlobalShortcut(keyCode: 63, modifiers: [.control]))
    }

    func testNormalizesUnrelatedFlagsAndRoundTrips() throws {
        let shortcut = try XCTUnwrap(GlobalShortcut(
            keyCode: 11, modifiers: [.command, .shift, .capsLock, .numericPad]))
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
        XCTAssertEqual(GlobalShortcut(storedValue: shortcut.storedValue), shortcut)
    }
}

final class TakeoverShortcutModelTests: XCTestCase {
    func testCaptureSuspendsThenAppliesShortcut() throws {
        let model = ControlsModel()
        var recordingChanges: [Bool] = []
        var changedShortcut: GlobalShortcut?
        model.onShortcutRecordingChanged = { recordingChanges.append($0) }
        model.onShortcutChanged = { changedShortcut = $0; return nil }

        model.recordShortcut()
        model.assignShortcut(keyCode: 11, modifiers: [.command, .shift])

        let expected = try XCTUnwrap(GlobalShortcut(
            keyCode: 11, modifiers: [.command, .shift]))
        XCTAssertEqual(recordingChanges, [true, false])
        XCTAssertEqual(changedShortcut, expected)
        XCTAssertEqual(model.takeoverShortcut, expected)
        XCTAssertFalse(model.recordingShortcut)
    }

    func testInvalidCaptureRemainsArmed() {
        let model = ControlsModel()
        var changeCount = 0
        model.onShortcutChanged = { _ in changeCount += 1; return nil }

        model.recordShortcut()
        model.assignShortcut(keyCode: 5, modifiers: [.shift])

        XCTAssertTrue(model.recordingShortcut)
        XCTAssertEqual(changeCount, 0)
        XCTAssertNotNil(model.shortcutMessage)
    }

    func testRegistrationFailureKeepsPreviousShortcut() {
        let model = ControlsModel()
        let previous = GlobalShortcut.defaultTakeover
        model.takeoverShortcut = previous
        model.onShortcutChanged = { _ in "That shortcut is already in use." }

        model.recordShortcut()
        model.assignShortcut(keyCode: 11, modifiers: [.command])

        XCTAssertEqual(model.takeoverShortcut, previous)
        XCTAssertEqual(model.shortcutMessage, "That shortcut is already in use.")
        XCTAssertFalse(model.recordingShortcut)
    }

    func testClearDisablesShortcut() {
        let model = ControlsModel()
        var didClear = false
        model.onShortcutChanged = { shortcut in
            didClear = shortcut == nil
            return nil
        }

        model.clearShortcut()

        XCTAssertTrue(didClear)
        XCTAssertNil(model.takeoverShortcut)
    }
}
