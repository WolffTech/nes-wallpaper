// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// A menu-bar-sized rendering of the four-pane app mark.
///
/// Status items are template images: AppKit uses the artwork as a mask and
/// supplies the appropriate color for the current menu-bar appearance and
/// highlighted state. Drawing the mark as paths also keeps it crisp at every
/// backing scale without bundling separate 1x and 2x bitmaps.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func makeImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { bounds in
            draw(in: bounds)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NES Wallpaper"
        return image
    }

    private static func draw(in bounds: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The 14-point mark leaves two points of breathing room on every side
        // of the standard 18-point menu-bar image canvas. A two-point gutter
        // keeps the four panes distinct at 1x as well as Retina resolutions.
        let scale = min(bounds.width, bounds.height) / size.width
        let markSize = 14 * scale
        let paneSize = 6 * scale
        let gutter = 2 * scale
        let origin = CGPoint(
            x: bounds.midX - markSize / 2,
            y: bounds.midY - markSize / 2)
        let innerRadius = 1 * scale
        let outerRadius = 2 * scale

        let bottomLeft = CGRect(
            x: origin.x,
            y: origin.y,
            width: paneSize,
            height: paneSize)
        let bottomRight = bottomLeft.offsetBy(dx: paneSize + gutter, dy: 0)
        let topLeft = bottomLeft.offsetBy(dx: 0, dy: paneSize + gutter)
        let topRight = bottomRight.offsetBy(dx: 0, dy: paneSize + gutter)

        context.setFillColor(NSColor.black.cgColor)
        context.addPath(roundedRect(
            topLeft,
            topLeft: outerRadius,
            topRight: innerRadius,
            bottomRight: innerRadius,
            bottomLeft: innerRadius))
        context.addPath(roundedRect(
            topRight,
            topLeft: innerRadius,
            topRight: outerRadius,
            bottomRight: innerRadius,
            bottomLeft: innerRadius))
        context.addPath(roundedRect(
            bottomLeft,
            topLeft: innerRadius,
            topRight: innerRadius,
            bottomRight: innerRadius,
            bottomLeft: outerRadius))
        context.addPath(roundedRect(
            bottomRight,
            topLeft: innerRadius,
            topRight: innerRadius,
            bottomRight: outerRadius,
            bottomLeft: innerRadius))
        context.fillPath()
    }

    private static func roundedRect(
        _ rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomRight: CGFloat,
        bottomLeft: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + bottomLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + bottomRight),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - topRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + topLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - topLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottomLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
