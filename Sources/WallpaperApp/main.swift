import AppKit
import CFCEUX

// Minimal wallpaper demo: runs one FCEUX instance and renders it tiled onto a
// borderless window at desktop level (behind icons) on the main screen.
// Usage: nes-wallpaper <rom> [--movie file.fm2]

var romPath: String?
var moviePath: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--movie": moviePath = args.isEmpty ? nil : args.removeFirst()
    default: romPath = arg
    }
}

guard let romPath else {
    FileHandle.standardError.write("usage: nes-wallpaper <rom> [--movie file.fm2]\n".data(using: .utf8)!)
    exit(2)
}

final class EmulatorView: NSView {
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        // NES NTSC runs at 60.0988 fps; a 60 Hz timer is fine for a demo.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0988, repeats: true) { [weak self] _ in
            self?.stepFrame()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stepFrame() {
        guard let rgba = fceux_run_frame(0) else { return }
        let width = Int(fceux_frame_width())
        let height = Int(fceux_frame_height())
        let data = CFDataCreate(nil, rgba, width * height * 4)!
        let provider = CGDataProvider(data: data)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { exit(1) }

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false

        let view = EmulatorView(frame: screen.frame)
        window.contentView = view
        window.orderFront(nil)

        view.start()
    }
}

let baseDir = NSTemporaryDirectory().appending("fceux-wallpaper")
try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

guard fceux_init(baseDir) != 0 else { fatalError("fceux_init failed") }
guard fceux_load_game(romPath) != 0 else { fatalError("failed to load ROM: \(romPath)") }
if let moviePath {
    guard fceux_load_movie(moviePath) != 0 else { fatalError("failed to load movie: \(moviePath)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
let delegate = AppDelegate()
app.delegate = delegate
app.run()
