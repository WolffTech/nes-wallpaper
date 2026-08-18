// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import NESWallpaperCore

final class TileGeometryTests: XCTestCase {
    func testFullscreenPillarboxesRawFrameOnWideDisplay() {
        // 256x240 (~1.07) on a 3456x2234 (~1.55) drawable: height-limited,
        // side bars, centered.
        let fit = TileGridRenderer.aspectFitRect(
            textureWidth: 256, textureHeight: 240,
            in: CGRect(x: 0, y: 0, width: 3456, height: 2234))
        XCTAssertEqual(fit.height, 2234, accuracy: 0.001)
        XCTAssertEqual(fit.minY, 0, accuracy: 0.001)
        XCTAssertEqual(fit.width, 2234 * 256 / 240, accuracy: 0.001)
        XCTAssertEqual(fit.midX, 3456 / 2, accuracy: 0.001)
    }

    func testFullscreenLetterboxesWideFrameOnTallCell() {
        // NTSC-filtered 602x480 (~1.25) into a 500x600 cell: width-limited,
        // top/bottom bars, centered.
        let fit = TileGridRenderer.aspectFitRect(
            textureWidth: 602, textureHeight: 480,
            in: CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(fit.width, 500, accuracy: 0.001)
        XCTAssertEqual(fit.minX, 0, accuracy: 0.001)
        XCTAssertEqual(fit.height, 500 * 480 / 602, accuracy: 0.001)
        XCTAssertEqual(fit.midY, 300, accuracy: 0.001)
    }

    func testDownscaleStaysWithinOffsetCell() {
        // A cell smaller than the texture, offset from the origin, as in
        // the grid loop: the fit must shrink and stay centered in the cell.
        let cell = CGRect(x: 100, y: 50, width: 128, height: 128)
        let fit = TileGridRenderer.aspectFitRect(
            textureWidth: 256, textureHeight: 240, in: cell)
        XCTAssertEqual(fit.width, 128, accuracy: 0.001)
        XCTAssertEqual(fit.height, 128 * 240 / 256, accuracy: 0.001)
        XCTAssertEqual(fit.midX, cell.midX, accuracy: 0.001)
        XCTAssertEqual(fit.midY, cell.midY, accuracy: 0.001)
        XCTAssertTrue(cell.insetBy(dx: -0.001, dy: -0.001).contains(fit))
    }
}
