import XCTest
@testable import NESWallpaperCore

final class TileGridHitTestTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 600)

    func testRowMajorFromTopLeftInBottomUpCoordinates() {
        // 3x2 grid: cells are 400x300. AppKit y grows upward, tile rows
        // grow downward, so the top-left tile is high-y, low-x.
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 10, y: 590), in: size, columns: 3, rows: 2), 0)
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 1190, y: 590), in: size, columns: 3, rows: 2), 2)
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 10, y: 10), in: size, columns: 3, rows: 2), 3)
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 1190, y: 10), in: size, columns: 3, rows: 2), 5)
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 600, y: 300), in: size, columns: 3, rows: 2), 1)
    }

    func testCellBoundaries() {
        // A point exactly on a cell edge belongs to the higher cell, and the
        // far window edges are out of bounds rather than a phantom cell.
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 400, y: 599), in: size, columns: 3, rows: 2), 1)
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 0, y: 300), in: size, columns: 3, rows: 2), 0)
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: CGPoint(x: 1200, y: 10), in: size, columns: 3, rows: 2))
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: CGPoint(x: 10, y: 600), in: size, columns: 3, rows: 2))
    }

    func testOutsideAndDegenerateInputs() {
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: CGPoint(x: -1, y: 10), in: size, columns: 3, rows: 2))
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: CGPoint(x: 10, y: -1), in: size, columns: 3, rows: 2))
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: .zero, in: .zero, columns: 3, rows: 2))
        XCTAssertNil(TileGridHitTest.tileIndex(
            at: .zero, in: size, columns: 0, rows: 2))
    }

    func testSingleTileGrid() {
        XCTAssertEqual(TileGridHitTest.tileIndex(
            at: CGPoint(x: 600, y: 300), in: size, columns: 1, rows: 1), 0)
    }
}
