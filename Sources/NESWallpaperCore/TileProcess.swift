import AppKit
import CShm

/// One wallpaper tile: a nes-helper child process publishing frames into
/// POSIX shared memory, plus the app-side reader for that segment.
public final class TileProcess {
    public let shmName: String

    private let process: Process
    private let stdin: FileHandle
    private var shm: UnsafeMutablePointer<nes_shm_t>?

    public init(helper: URL, shmName: String, rom: String, movie: String?,
                startFrame: Int = 0, loop: Bool = true, filter: VideoFilter = .none) throws {
        self.shmName = shmName
        var arguments = ["--shm", shmName, "--rom", rom, "--filter", filter.rawValue]
        if let movie {
            arguments += ["--movie", movie]
            if startFrame > 0 { arguments += ["--start-frame", String(startFrame)] }
            if loop { arguments.append("--loop") }
        }
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
