import AppKit
import NESWallpaperCore

// Tiled NES wallpaper: one nes-helper process per grid cell publishes frames
// into shared memory; this app renders the grid on a borderless window at
// desktop level (behind icons).
// Usage: nes-wallpaper [--grid CxR] <rom[:movie.fm2]>...

func usage() -> Never {
    FileHandle.standardError.write(
        Data("usage: nes-wallpaper [--grid CxR] <rom[:movie.fm2]>...\n".utf8))
    exit(2)
}

var columns = 3
var rows = 2
var pairs: [(rom: String, movie: String?)] = []

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
    default:
        if let colon = arg.firstIndex(of: ":") {
            pairs.append((rom: String(arg[..<colon]),
                          movie: String(arg[arg.index(after: colon)...])))
        } else {
            pairs.append((rom: arg, movie: nil))
        }
    }
}

guard !pairs.isEmpty else { usage() }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WallpaperController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            FileHandle.standardError.write(Data("nes-wallpaper: no screen\n".utf8))
            exit(1)
        }
        do {
            controller = try WallpaperController(
                pairs: pairs, columns: columns, rows: rows, screens: [screen])
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
