import XCTest
@testable import NESWallpaperCore

final class TakeoverKeymapTests: XCTestCase {
    func testDocumentedLayout() {
        XCTAssertEqual(TakeoverKeymap.button(for: 7), .a)        // X
        XCTAssertEqual(TakeoverKeymap.button(for: 6), .b)        // Z
        XCTAssertEqual(TakeoverKeymap.button(for: 36), .start)   // Return
        XCTAssertEqual(TakeoverKeymap.button(for: 76), .start)   // keypad Enter
        XCTAssertEqual(TakeoverKeymap.button(for: 123), .left)
        XCTAssertEqual(TakeoverKeymap.button(for: 124), .right)
        XCTAssertEqual(TakeoverKeymap.button(for: 125), .down)
        XCTAssertEqual(TakeoverKeymap.button(for: 126), .up)
    }

    func testSessionControlKeysAreNotButtons() {
        // Esc ends the session and Right Shift arrives via flagsChanged;
        // neither may double as a pad button.
        XCTAssertNil(TakeoverKeymap.button(for: TakeoverKeymap.escapeKeyCode))
        XCTAssertNil(TakeoverKeymap.button(for: TakeoverKeymap.rightShiftKeyCode))
    }
}
