import Foundation
import CFCEUX
import CShm

// Usage: nes-helper --shm <frame-file-path> --rom <path> [--movie <path.fm2>]
//        [--start-frame N] [--loop] [--filter <name>] [--low-power]
//
// Runs one FCEUX instance at the NES NTSC rate and publishes frames into a
// shared frame file (created here, mmapped by readers) at 60 fps normally or
// 30 fps in Low Power Mode. Quits on SIGTERM/SIGINT, stdin "quit"/EOF, or orphaning.
// --start-frame fast-forwards the movie (unpaced, render skipped) so the
// tile starts mid-game, like the original saver's checkpoints.

func log(_ msg: String) {
    FileHandle.standardError.write("nes-helper[\(getpid())]: \(msg)\n".data(using: .utf8)!)
}

// Filter name -> (specfilt, specfilteropt) for fceux_set_video_filter.
// Deliberately duplicated from NESWallpaperCore's VideoFilter (the helper
// must not link AppKit); keep the two in sync.
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

var shmName: String?
var romPath: String?
var moviePath: String?
var startFrame = 0
var loopMovie = false
var filterName = "none"
var initialLowPowerMode = false
var badArgs = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--shm" where !args.isEmpty: shmName = args.removeFirst()
    case "--rom" where !args.isEmpty: romPath = args.removeFirst()
    case "--movie" where !args.isEmpty: moviePath = args.removeFirst()
    case "--start-frame" where !args.isEmpty:
        guard let n = Int(args.removeFirst()), n >= 0 else { badArgs = true; break }
        startFrame = n
    case "--loop": loopMovie = true
    case "--low-power": initialLowPowerMode = true
    case "--filter" where !args.isEmpty: filterName = args.removeFirst()
    default: badArgs = true
    }
}

guard !badArgs, let shmName, let romPath, let filter = filterMap[filterName] else {
    FileHandle.standardError.write("usage: nes-helper --shm <frame-file-path> --rom <path> [--movie <path.fm2>] [--start-frame N] [--loop] [--filter \(filterMap.keys.sorted().joined(separator: "|"))] [--low-power]\n".data(using: .utf8)!)
    exit(2)
}

// Control state shared between the main loop, signal sources, and stdin.
// The condition lets a paused helper sleep indefinitely instead of waking at
// the emulation cadence just to discover that it is still paused.
let stateCondition = NSCondition()
var wantQuit = false
var paused = false
var lowPowerMode = initialLowPowerMode

func setQuit() {
    stateCondition.lock()
    wantQuit = true
    stateCondition.broadcast()
    stateCondition.unlock()
}
func setPaused(_ value: Bool) {
    stateCondition.lock()
    paused = value
    stateCondition.broadcast()
    stateCondition.unlock()
}
func setLowPowerMode(_ value: Bool) {
    stateCondition.lock()
    lowPowerMode = value
    stateCondition.broadcast()
    stateCondition.unlock()
}
func readState() -> (quit: Bool, paused: Bool, lowPower: Bool) {
    stateCondition.lock(); defer { stateCondition.unlock() }
    return (wantQuit, paused, lowPowerMode)
}
func waitUntilRunnable() -> (quit: Bool, resumed: Bool) {
    stateCondition.lock(); defer { stateCondition.unlock() }
    var waited = false
    while paused && !wantQuit {
        waited = true
        stateCondition.wait()
    }
    return (wantQuit, waited)
}

// Anchor sidecar ("<movie>.anchors", written by the movie converter): FCEUX
// savestates force-loaded at fixed movie frames to re-sync playback of movies
// recorded on other emulator cores. Format: 'NWAN', u32 version, u32 count,
// then per anchor {u32 frame, u32 size, u8 blob[size]}, frames ascending.
struct MovieAnchors {
    let frames: [Int]
    let blobs: [Data]

    static func load(forMovie moviePath: String) -> MovieAnchors? {
        guard let d = FileManager.default.contents(atPath: moviePath + ".anchors"),
              d.count >= 12, d.prefix(4) == Data("NWAN".utf8) else { return nil }
        func u32(_ o: Int) -> Int {
            Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
        }
        guard u32(4) == 1 else { log("anchors: unsupported version"); return nil }
        var frames: [Int] = [], blobs: [Data] = []
        var o = 12
        for _ in 0..<u32(8) {
            guard o + 8 <= d.count else { return nil }
            let frame = u32(o), size = u32(o + 4)
            guard o + 8 + size <= d.count else { return nil }
            frames.append(frame)
            blobs.append(d.subdata(in: (o + 8)..<(o + 8 + size)))
            o += 8 + size
        }
        return MovieAnchors(frames: frames, blobs: blobs)
    }
}

let anchors: MovieAnchors? = moviePath.flatMap(MovieAnchors.load(forMovie:))
var nextAnchor = 0

// Call before emulating each frame (paced loop and fast-forward alike); loads
// the anchor state whose frame matches the current movie frame.
func applyAnchorIfDue() {
    guard let anchors, nextAnchor < anchors.frames.count else { return }
    let frame = Int(fceux_movie_frame())
    while nextAnchor < anchors.frames.count, anchors.frames[nextAnchor] < frame {
        nextAnchor += 1
    }
    guard nextAnchor < anchors.frames.count, anchors.frames[nextAnchor] == frame else { return }
    let ok = anchors.blobs[nextAnchor].withUnsafeBytes { raw in
        fceux_state_load(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
    }
    if ok == 0 { log("anchor at frame \(frame) failed to load") }
    nextAnchor += 1
}

let baseDir = NSTemporaryDirectory().appending("fceux-helper-\(getpid())")
try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

guard fceux_init(baseDir) != 0 else { log("fceux_init failed"); exit(1) }
guard fceux_load_game(romPath) != 0 else { log("failed to load ROM: \(romPath)"); exit(1) }
if let moviePath {
    guard fceux_load_movie(moviePath) != 0 else { log("failed to load movie: \(moviePath)"); exit(1) }
}
// After load_game: the NTSC blit path requires a loaded game.
guard fceux_set_video_filter(filter.0, filter.1) != 0 else {
    log("failed to set video filter \(filterName)"); exit(1)
}
let frameWidth = Int(fceux_frame_width())
let frameHeight = Int(fceux_frame_height())

guard let shm = nes_shm_create(shmName, UInt32(frameWidth), UInt32(frameHeight)) else {
    log("failed to create shm \(shmName)"); exit(1)
}
log("started: shm=\(shmName) rom=\(romPath) movie=\(moviePath ?? "none")\(loopMovie ? " loop" : "") filter=\(filterName) \(frameWidth)x\(frameHeight)\(initialLowPowerMode ? " low-power" : "")")
if let anchors { log("loaded \(anchors.frames.count) movie anchors") }

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "signals")
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
termSource.setEventHandler { log("SIGTERM"); setQuit() }
intSource.setEventHandler { log("SIGINT"); setQuit() }
termSource.resume()
intSource.resume()

Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        switch line.trimmingCharacters(in: .whitespaces) {
        case "quit": log("stdin quit"); setQuit(); return
        case "pause": log("paused"); setPaused(true)
        case "resume": log("resumed"); setPaused(false)
        case "low-power": log("low-power mode"); setLowPowerMode(true)
        case "normal-power": log("normal-power mode"); setLowPowerMode(false)
        default: break
        }
    }
    log("stdin EOF")
    setQuit()
}

// Fast-forward to the requested movie frame: unpaced, render skipped, nothing
// published (the reader tolerates a black tile while frame_count is 0). Stops
// early if the movie is shorter than the request. Only the initial playback
// fast-forwards; a --loop restart goes back to frame 0.
if moviePath != nil, startFrame > 0 {
    let ffStart = DispatchTime.now()
    var skipped = 0
    while fceux_movie_frame() < startFrame, fceux_movie_is_playing() != 0, !readState().quit {
        applyAnchorIfDue()
        _ = fceux_run_frame(2) // exact emulation, no conversion or publication
        skipped += 1
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds &- ffStart.uptimeNanoseconds)
        / 1_000_000_000.0
    log(String(format: "fast-forwarded %d frames to movie frame %d in %.2fs%@",
               skipped, fceux_movie_frame(), seconds,
               fceux_movie_is_playing() == 0 ? " (movie ended early)" : ""))
}

// The paced schedule's start reference is taken here, after any fast-forward,
// so the loop does not burst-run to "catch up" on the fast-forward time.
let frameNanos = 1_000_000_000.0 / 60.0988
var scheduleStart = DispatchTime.now()
var tick: UInt64 = 0
var emulatedFrameCount: UInt64 = 0
var publishedFrameCount: UInt32 = 0
var lastPpidCheck = scheduleStart
var movieEnded = false

emulation: while true {
    let permission = waitUntilRunnable()
    if permission.quit { break emulation }
    if permission.resumed {
        // Do not burst-run frames to catch up with time spent paused.
        scheduleStart = DispatchTime.now()
        tick = 0
    }

    // Drift-corrected deadline from the fixed start time, not accumulated sleeps.
    tick += 1
    let deadline = scheduleStart.uptimeNanoseconds &+ UInt64(Double(tick) * frameNanos)
    var now = DispatchTime.now().uptimeNanoseconds
    while now < deadline {
        // A direct kernel sleep avoids Foundation timer machinery in every
        // helper, while the loop still handles an early wake without drift.
        usleep(useconds_t((deadline - now + 999) / 1_000))
        now = DispatchTime.now().uptimeNanoseconds
    }

    if DispatchTime.now().uptimeNanoseconds - lastPpidCheck.uptimeNanoseconds > 1_000_000_000 {
        lastPpidCheck = DispatchTime.now()
        if getppid() == 1 { log("orphaned (parent died)"); break emulation }
    }

    let state = readState()
    if state.quit { break emulation }
    if state.paused { continue }

    applyAnchorIfDue()

    // Low Power Mode preserves every emulated frame (and therefore TAS and
    // game timing) but converts and publishes only alternate frames.
    let shouldPublish = !state.lowPower || emulatedFrameCount.isMultiple(of: 2)
    if shouldPublish {
        let back = 1 - nes_shm_load(&shm.pointee.front)
        guard fceux_run_frame_into(
            nes_shm_pixels(shm, back), Int32(shm.pointee.pitch)) != 0 else {
            log("failed to render into shared frame buffer; exiting")
            break emulation
        }
        nes_shm_store(&shm.pointee.front, back)
        publishedFrameCount &+= 1
        nes_shm_store(&shm.pointee.frame_count, publishedFrameCount)
        nes_shm_store(&shm.pointee.movie_playing, UInt32(fceux_movie_is_playing()))
        nes_shm_store(&shm.pointee.movie_frame, UInt32(max(0, fceux_movie_frame())))
    } else {
        _ = fceux_run_frame(2) // exact core frame, no color conversion
    }
    emulatedFrameCount &+= 1

    if let moviePath, !movieEnded, fceux_movie_is_playing() == 0 {
        if loopMovie {
            if fceux_load_movie(moviePath) != 0, fceux_movie_is_playing() != 0 {
                log("movie finished, restarting")
                nextAnchor = 0
            } else {
                log("movie finished, restart failed; continuing without input")
                movieEnded = true
            }
        } else {
            log("movie finished, continuing without input")
            movieEnded = true
        }
    }
}

nes_shm_close(shm, shmName, 1)
log("exiting")
