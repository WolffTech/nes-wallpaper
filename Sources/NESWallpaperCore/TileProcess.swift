import AppKit
import CShm

/// Anything TileGridRenderer can pull frames from: the app's live helper
/// processes, or the screensaver's read-only mappings of their frame files.
public protocol TileFrameSource {
    /// Frames published so far; the renderer skips the upload when unchanged.
    var frameCount: UInt32 { get }
    /// Runs body with the last completed buffer and its bytesPerRow,
    /// returning the frame count sampled alongside it; nil while no
    /// segment is mapped.
    func withFrontBuffer<R>(_ body: (UnsafeRawPointer, _ bytesPerRow: Int) -> R)
        -> (frameCount: UInt32, result: R)?
}

/// Read-only mapping of one tile's frame file, for readers outside the app
/// (the screensaver plugin). The writer is not our child: the mapping just
/// goes quiet when the helper dies, and the file vanishes for later opens.
public final class MappedTile: TileFrameSource {
    private let shm: UnsafeMutablePointer<nes_shm_t>
    public let path: String

    public init?(path: String) {
        guard let shm = nes_shm_open(path) else { return nil }
        self.shm = shm
        self.path = path
    }

    deinit { nes_shm_close(shm, path, 0) }

    public var frameCount: UInt32 { nes_shm_load(&shm.pointee.frame_count) }

    public var frameSize: (width: Int, height: Int) {
        (Int(shm.pointee.width), Int(shm.pointee.height))
    }

    public func withFrontBuffer<R>(_ body: (UnsafeRawPointer, _ bytesPerRow: Int) -> R)
        -> (frameCount: UInt32, result: R)?
    {
        let count = nes_shm_load(&shm.pointee.frame_count)
        let idx = nes_shm_load(&shm.pointee.front)
        let result = body(nes_shm_pixels(shm, idx), Int(shm.pointee.pitch))
        return (count, result)
    }
}

/// One wallpaper tile: a nes-helper child process publishing frames into a
/// shared frame file (see SharedFrames), plus the app-side reader for it.
public final class TileProcess: TileFrameSource {
    public let shmName: String

    private let process: Process
    private let stdin: FileHandle
    private var shm: UnsafeMutablePointer<nes_shm_t>?

    public init(helper: URL, shmName: String, rom: String, movie: String?,
                startFrame: Int = 0, loop: Bool = true,
                filter: VideoFilter = .none, lowPowerMode: Bool = false) throws {
        self.shmName = shmName
        var arguments = ["--shm", shmName, "--rom", rom, "--filter", filter.rawValue]
        if let movie {
            arguments += ["--movie", movie]
            if startFrame > 0 { arguments += ["--start-frame", String(startFrame)] }
            if loop { arguments.append("--loop") }
        }
        if lowPowerMode { arguments.append("--low-power") }
        let pipe = Pipe()
        process = Process()
        process.executableURL = helper
        process.arguments = arguments
        // Keep a pipe to the helper's stdin: it carries pause/resume, and the
        // helper quits on EOF, so helpers die with the app even if teardown
        // never runs.
        process.standardInput = pipe
        stdin = pipe.fileHandleForWriting
        try process.run()
    }

    /// The helper creates the segment only after it has loaded the ROM, so
    /// poll every 50ms until it appears. Returns false on timeout or if the
    /// helper has already exited.
    public func openSharedMemory(timeout: TimeInterval = 5.0) -> Bool {
        if shm != nil { return true }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let mapped = nes_shm_open(shmName) {
                shm = mapped
                return true
            }
            if !process.isRunning || Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    public var frameCount: UInt32 {
        guard let shm else { return 0 }
        return nes_shm_load(&shm.pointee.frame_count)
    }

    /// Frame dimensions from the shm header, once the segment is open.
    public var frameSize: (width: Int, height: Int)? {
        guard let shm else { return nil }
        return (Int(shm.pointee.width), Int(shm.pointee.height))
    }

    /// Runs body with the last completed buffer (acquire-load of `front`)
    /// and its bytesPerRow, returning the frame_count sampled alongside it.
    /// Same tearing guarantees as ever: the buffer may be republished while
    /// body runs only if the helper laps a whole frame, which the double
    /// buffer prevents. nil until the segment is open.
    public func withFrontBuffer<R>(_ body: (UnsafeRawPointer, _ bytesPerRow: Int) -> R)
        -> (frameCount: UInt32, result: R)?
    {
        guard let shm else { return nil }
        let count = nes_shm_load(&shm.pointee.frame_count)
        let idx = nes_shm_load(&shm.pointee.front)
        let result = body(nes_shm_pixels(shm, idx), Int(shm.pointee.pitch))
        return (count, result)
    }

    public func pause() { send("pause\n") }
    public func resume() { send("resume\n") }
    public func setLowPowerMode(_ enabled: Bool) {
        send(enabled ? "low-power\n" : "normal-power\n")
    }

    private func send(_ command: String) {
        guard process.isRunning else { return }
        try? stdin.write(contentsOf: Data(command.utf8))
    }

    /// Close stdin (the helper quits on EOF), send SIGTERM as well, then
    /// wait briefly for it to exit and unmap the segment.
    public func terminate() {
        try? stdin.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<20 where process.isRunning { usleep(10_000) }
        if let shm {
            nes_shm_close(shm, shmName, 0)
            self.shm = nil
        }
    }

    deinit { terminate() }
}
