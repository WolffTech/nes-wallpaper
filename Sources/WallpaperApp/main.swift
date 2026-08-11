import AppKit
import NESWallpaperCore

// Tiled NES wallpaper: one nes-helper process per grid cell publishes frames
// into shared memory; this app renders the grid on a borderless window at
// desktop level (behind icons).
// Usage: nes-wallpaper [--grid CxR] [--rotate SECONDS] [--start-frame N]
//        <rom[:movie.fm2]>...
//        nes-wallpaper [--grid CxR] [--rotate SECONDS] --roms DIR --movies DIR

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: nes-wallpaper [--grid CxR] [--rotate SECONDS] [--start-frame N] <rom[:movie.fm2]>...
           nes-wallpaper [--grid CxR] [--rotate SECONDS] --roms DIR --movies DIR

    """.utf8))
    exit(2)
}

var columns = 3
var rows = 2
var rotationInterval: TimeInterval?
var startFrame = 0
var pairs: [(rom: String, movie: String?)] = []
var romsDir: String?
var moviesDir: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--grid":
        guard !args.isEmpty else { usage() }
        let parts = args.removeFirst().lowercased().split(separator: "x")
        guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]),
              c > 0, r > 0 else { usage() }
        columns = c
        rows = r
    case "--rotate":
        guard !args.isEmpty, let seconds = Double(args.removeFirst()), seconds > 0 else { usage() }
        rotationInterval = seconds
    case "--start-frame":
        guard !args.isEmpty, let n = Int(args.removeFirst()), n >= 0 else { usage() }
        startFrame = n
    case "--roms":
        guard !args.isEmpty else { usage() }
        romsDir = args.removeFirst()
    case "--movies":
        guard !args.isEmpty else { usage() }
        moviesDir = args.removeFirst()
    default:
        if let colon = arg.firstIndex(of: ":") {
            pairs.append((rom: String(arg[..<colon]),
                          movie: String(arg[arg.index(after: colon)...])))
        } else {
            pairs.append((rom: arg, movie: nil))
        }
    }
}

guard !pairs.isEmpty || (romsDir != nil && moviesDir != nil) else { usage() }

// Library mode: each tile picks a random matched rom/movie pair and starts at
// a random point in the first 70% of the movie, like the original saver's
// checkpoints. Explicit pairs mode keeps the CLI-provided order and startFrame.
func makeTileSource() -> () -> TileSpec {
    if let romsDir, let moviesDir {
        let library = ContentLibrary(
            romsDir: URL(fileURLWithPath: romsDir, isDirectory: true),
            moviesDir: URL(fileURLWithPath: moviesDir, isDirectory: true))
        guard !library.matches.isEmpty else {
            FileHandle.standardError.write(Data("nes-wallpaper: no rom/movie matches in library\n".utf8))
            exit(1)
        }
        return {
            let match = library.randomMatch()!
            let maxStart = Int(Double(match.frameCount) * 0.7)
            return TileSpec(
                rom: match.romURL.path,
                movie: match.movieURL.path,
                startFrame: maxStart > 0 ? Int.random(in: 0...maxStart) : 0)
        }
    }
    var pairIndex = 0
    return {
        defer { pairIndex += 1 }
        let pair = pairs[pairIndex % pairs.count]
        return TileSpec(rom: pair.rom, movie: pair.movie, startFrame: startFrame)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WallpaperController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            FileHandle.standardError.write(Data("nes-wallpaper: no screen\n".utf8))
            exit(1)
        }
        do {
            controller = try WallpaperController(
                tileSource: makeTileSource(),
                rotationInterval: rotationInterval,
                columns: columns, rows: rows, screens: [screen])
        } catch {
            FileHandle.standardError.write(Data("nes-wallpaper: \(error)\n".utf8))
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

// A dying helper must not kill us via EPIPE on its stdin pipe.
signal(SIGPIPE, SIG_IGN)

// Route SIGTERM/SIGINT through NSApp.terminate so applicationWillTerminate
// runs and the helpers are torn down.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
let delegate = AppDelegate()
app.delegate = delegate
app.run()
