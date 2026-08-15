// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import XCTest
@testable import nes_wallpaper

final class MenuBarIconTests: XCTestCase {
    func testImageUsesMenuBarTemplateConventions() {
        let image = MenuBarIcon.makeImage()

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "NES Wallpaper")
    }

    func testImageCanRenderAtRetinaScale() {
        let image = MenuBarIcon.makeImage()
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)

        XCTAssertNotNil(representation)
        guard let representation else { return }
        representation.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return XCTFail("Could not create a bitmap graphics context")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        // Each pane has ink, while the center gutter and canvas corner remain
        // transparent so macOS can tint only the mark.
        XCTAssertGreaterThan(representation.colorAt(x: 10, y: 10)?.alphaComponent ?? 0, 0)
        XCTAssertGreaterThan(representation.colorAt(x: 26, y: 10)?.alphaComponent ?? 0, 0)
        XCTAssertGreaterThan(representation.colorAt(x: 10, y: 26)?.alphaComponent ?? 0, 0)
        XCTAssertGreaterThan(representation.colorAt(x: 26, y: 26)?.alphaComponent ?? 0, 0)
        XCTAssertEqual(representation.colorAt(x: 18, y: 18)?.alphaComponent ?? 1, 0)
        XCTAssertEqual(representation.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0)
    }
}
