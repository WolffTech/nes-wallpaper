// Renders the app icon from source artwork: scales the (square, full-bleed)
// logo into the standard macOS icon shape — an 824/1024 rounded rect centered
// on a transparent 1024 canvas — at every size an .iconset needs.
//
// Usage: swift make-icon.swift <source.png> <output.iconset>
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <output.iconset>\n".utf8))
    exit(64)
}
let sourcePath = CommandLine.arguments[1]
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard let source = NSImage(contentsOfFile: sourcePath),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("error: cannot read image: \(sourcePath)\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func render(pixels: Int, to url: URL) throws {
    let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Apple's icon grid: on a 1024pt canvas the icon body is an 824pt
    // rounded rect (~185pt corner radius) centered with 100pt margins.
    let size = CGFloat(pixels)
    let body = CGRect(x: 0, y: 0, width: size, height: size)
        .insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024)
    let radius = size * 185.4 / 1024

    context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(sourceCG, in: body)

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, to: iconsetURL.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2, to: iconsetURL.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
