import Foundation
import CFCEUX
import CShm

// Usage: nes-helper --shm /nes.<pid>.<idx> --rom <path> [--movie <path.fm2>]
//        [--start-frame N] [--loop]
//
// Runs one FCEUX instance and publishes frames into a shared-memory segment
// at NES NTSC rate. Quits on SIGTERM/SIGINT, stdin "quit"/EOF, or orphaning.
// --start-frame fast-forwards the movie (unpaced, render skipped) so the
// tile starts mid-game, like the original saver's checkpoints.

func log(_ msg: String) {
    FileHandle.standardError.write("nes-helper[\(getpid())]: \(msg)\n".data(using: .utf8)!)
}

var shmName: String?
var romPath: String?
var moviePath: String?
var startFrame = 0
var loopMovie = false
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
    default: badArgs = true
    }
}

guard !badArgs, let shmName, let romPath else {
    FileHandle.standardError.write("usage: nes-helper --shm /nes.<pid>.<idx> --rom <path> [--movie <path.fm2>] [--start-frame N] [--loop]\n".data(using: .utf8)!)
    exit(2)
}

// Control flags, shared between the main loop, signal sources, and the
// stdin reader thread.
let flagsLock = NSLock()
var wantQuit = false
var paused = false

func setQuit() { flagsLock.lock(); wantQuit = true; flagsLock.unlock() }
func setPaused(_ p: Bool) { flagsLock.lock(); paused = p; flagsLock.unlock() }
func readFlags() -> (quit: Bool, paused: Bool) {
    flagsLock.lock(); defer { flagsLock.unlock() }
    return (wantQuit, paused)
}

let baseDir = NSTemporaryDirectory().appending("fceux-helper-\(getpid())")
try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

guard fceux_init(baseDir) != 0 else { log("fceux_init failed"); exit(1) }
guard fceux_load_game(romPath) != 0 else { log("failed to load ROM: \(romPath)"); exit(1) }
if let moviePath {
    guard fceux_load_movie(moviePath) != 0 else { log("failed to load movie: \(moviePath)"); exit(1) }
}

guard let shm = nes_shm_create(shmName) else { log("failed to create shm \(shmName)"); exit(1) }
log("started: shm=\(shmName) rom=\(romPath) movie=\(moviePath ?? "none")\(loopMovie ? " loop" : "")")

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
        default: break
        }
    }
    log("stdin EOF")
    setQuit()
}

// Swift cannot import the `pixels` field (its array size comes from a macro),
// so locate it from the end of the struct: it is the last field, and the
// header words leave no tail padding.
let pixBytes = Int(NES_SHM_WIDTH * NES_SHM_HEIGHT * 4)
let pixelsBase = UnsafeMutableRawPointer(shm) + (MemoryLayout<nes_shm_t>.size - 2 * pixBytes)

// Fast-forward to the requested movie frame: unpaced, render skipped, nothing
// published (the reader tolerates a black tile while frame_count is 0). Stops
// early if the movie is shorter than the request. Only the initial playback
// fast-forwards; a --loop restart goes back to frame 0.
if moviePath != nil, startFrame > 0 {
    let ffStart = DispatchTime.now()
    var skipped = 0
    while fceux_movie_frame() < startFrame, fceux_movie_is_playing() != 0, !readFlags().quit {
        _ = fceux_run_frame(1) // skip_render: returns NULL, do not publish
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
let start = DispatchTime.now()
var tick: UInt64 = 0
var frameCount: UInt32 = 0
var lastPpidCheck = start
var movieEnded = false

emulation: while true {
    // Drift-corrected deadline from the fixed start time, not accumulated sleeps.
    tick += 1
    let deadline = start.uptimeNanoseconds &+ UInt64(Double(tick) * frameNanos)
    var now = DispatchTime.now().uptimeNanoseconds
    while now < deadline {
        Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000.0)
        now = DispatchTime.now().uptimeNanoseconds
    }

    if DispatchTime.now().uptimeNanoseconds - lastPpidCheck.uptimeNanoseconds > 1_000_000_000 {
        lastPpidCheck = DispatchTime.now()
        if getppid() == 1 { log("orphaned (parent died)"); break emulation }
    }

    let flags = readFlags()
    if flags.quit { break emulation }
    if flags.paused { continue }

    guard let rgba = fceux_run_frame(0) else { continue }
    let back = 1 - nes_shm_load(&shm.pointee.front)
    memcpy(pixelsBase + Int(back) * pixBytes, rgba, pixBytes)
    nes_shm_store(&shm.pointee.front, back)
    frameCount &+= 1
    nes_shm_store(&shm.pointee.frame_count, frameCount)
    nes_shm_store(&shm.pointee.movie_playing, UInt32(fceux_movie_is_playing()))
    nes_shm_store(&shm.pointee.movie_frame, UInt32(max(0, fceux_movie_frame())))

    if let moviePath, !movieEnded, fceux_movie_is_playing() == 0 {
        if loopMovie {
            if fceux_load_movie(moviePath) != 0, fceux_movie_is_playing() != 0 {
                log("movie finished, restarting")
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
