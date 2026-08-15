import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CFCEUX

// Usage: nes-headless <rom> [--movie file.fm2] [--frames N] [--dump-every N]
//        [--out dir] [--filter name] [--raw]

// Same name -> (specfilt, specfilteropt) map as nes-helper; see
// VideoFilter.swift in NESWallpaperCore.
let filterMap: [String: (Int32, Int32)] = [
    "none": (0, 0),
    "hq2x": (1, 0),
    "scale2x": (2, 0),
    "ntsc-composite": (3, 0),
    "ntsc-svideo": (3, 1),
    "ntsc-rgb": (3, 2),
    "ntsc-mono": (3, 3),
    "hq3x": (4, 0),
    "scale3x": (5, 0),
]

var romPath: String?
var moviePath: String?
var frames = 600
var dumpEvery = 0
var outDir = "frames"
var filterName = "none"
var dumpRaw = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--movie": moviePath = args.isEmpty ? nil : args.removeFirst()
    case "--frames": frames = Int(args.removeFirst()) ?? frames
    case "--dump-every": dumpEvery = Int(args.removeFirst()) ?? 0
    case "--out": outDir = args.removeFirst()
    case "--filter": filterName = args.isEmpty ? filterName : args.removeFirst()
    case "--raw": dumpRaw = true
    default: romPath = arg
    }
}

guard let romPath, let filter = filterMap[filterName] else {
    FileHandle.standardError.write("usage: nes-headless <rom> [--movie file.fm2] [--frames N] [--dump-every N] [--out dir] [--filter \(filterMap.keys.sorted().joined(separator: "|"))] [--raw]\n".data(using: .utf8)!)
    exit(2)
}

func writePNG(_ bgrx: UnsafePointer<UInt8>, width: Int, height: Int, to url: URL) {
    let data = CFDataCreate(nil, bgrx, width * height * 4)!
    let provider = CGDataProvider(data: data)!
    // The shim emits BGRX8888: little-endian 0x00RRGGBB words.
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
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

// After load_game: the NTSC blit path requires a loaded game.
guard fceux_set_video_filter(filter.0, filter.1) != 0 else {
    fatalError("failed to set video filter \(filterName)")
}

if dumpEvery > 0 {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
}

let width = Int(fceux_frame_width())
let height = Int(fceux_frame_height())
print("filter: \(filterName) (\(width)x\(height))")
let start = Date()

for frame in 0..<frames {
    let wantDump = dumpEvery > 0 && (frame % dumpEvery == 0 || frame == frames - 1)
    let bgrx = fceux_run_frame(0)
    if wantDump, let bgrx {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "frame_%06d.png", frame))
        writePNG(bgrx, width: width, height: height, to: url)
        if dumpRaw {
            // Raw BGRX bytes: byte-stable across OS releases, unlike PNG encoding.
            let raw = Data(bytes: bgrx, count: width * height * 4)
            try! raw.write(to: url.deletingPathExtension().appendingPathExtension("raw"))
        }
    }
    if moviePath != nil && fceux_movie_is_playing() == 0 {
        print("movie finished at frame \(fceux_movie_frame())")
        break
    }
}

let elapsed = Date().timeIntervalSince(start)
let emulated = Double(frames) / 60.0988
print(String(format: "ran %d frames in %.2fs (%.1fx real time)", frames, elapsed, emulated / elapsed))
