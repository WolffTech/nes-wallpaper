import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CFCEUX

// Usage: nes-headless <rom> [--movie file.fm2] [--frames N] [--dump-every N] [--out dir]

var romPath: String?
var moviePath: String?
var frames = 600
var dumpEvery = 0
var outDir = "frames"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--movie": moviePath = args.isEmpty ? nil : args.removeFirst()
    case "--frames": frames = Int(args.removeFirst()) ?? frames
    case "--dump-every": dumpEvery = Int(args.removeFirst()) ?? 0
    case "--out": outDir = args.removeFirst()
    default: romPath = arg
    }
}

guard let romPath else {
    FileHandle.standardError.write("usage: nes-headless <rom> [--movie file.fm2] [--frames N] [--dump-every N] [--out dir]\n".data(using: .utf8)!)
    exit(2)
}

func writePNG(_ rgba: UnsafePointer<UInt8>, width: Int, height: Int, to url: URL) {
    let data = CFDataCreate(nil, rgba, width * height * 4)!
    let provider = CGDataProvider(data: data)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let baseDir = NSTemporaryDirectory().appending("fceux-headless")
try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

guard fceux_init(baseDir) != 0 else { fatalError("fceux_init failed") }
guard fceux_load_game(romPath) != 0 else { fatalError("failed to load ROM: \(romPath)") }
print("loaded: \(romPath)")

if let moviePath {
    guard fceux_load_movie(moviePath) != 0 else { fatalError("failed to load movie: \(moviePath)") }
    print("movie playing: \(moviePath)")
}

if dumpEvery > 0 {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
}

let width = Int(fceux_frame_width())
let height = Int(fceux_frame_height())
let start = Date()

for frame in 0..<frames {
    let wantDump = dumpEvery > 0 && (frame % dumpEvery == 0 || frame == frames - 1)
    let rgba = fceux_run_frame(0)
    if wantDump, let rgba {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "frame_%06d.png", frame))
        writePNG(rgba, width: width, height: height, to: url)
    }
    if moviePath != nil && fceux_movie_is_playing() == 0 {
        print("movie finished at frame \(fceux_movie_frame())")
        break
    }
}

let elapsed = Date().timeIntervalSince(start)
let emulated = Double(frames) / 60.0988
print(String(format: "ran %d frames in %.2fs (%.1fx real time)", frames, elapsed, emulated / elapsed))
