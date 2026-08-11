import AppKit
import CShm

/// One wallpaper tile: a nes-helper child process publishing frames into
/// POSIX shared memory, plus the app-side reader for that segment.
public final class TileProcess {
    public let shmName: String

    private let process: Process
    private let stdin: FileHandle
    private var shm: UnsafeMutablePointer<nes_shm_t>?

    /// frame_count as of the last makeImage(); compare with frameCount to
    /// skip repaints when the helper hasn't published a new frame.
    public private(set) var lastFrameCount: UInt32 = 0

    public init(helper: URL, shmName: String, rom: String, movie: String?, loop: Bool = true) throws {
        self.shmName = shmName
        var arguments = ["--shm", shmName, "--rom", rom]
        if let movie {
            arguments += ["--movie", movie]
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

    /// Snapshot the last completed buffer as a CGImage. Copies the pixels
    /// out: the shm buffer will be rewritten while CoreAnimation still holds
    /// the image.
    public func makeImage() -> CGImage? {
        guard let shm else { return nil }
        let width = Int(NES_SHM_WIDTH)
        let height = Int(NES_SHM_HEIGHT)
        let pixbytes = width * height * 4 // NES_SHM_PIXBYTES (macro doesn't import)
        let idx = Int(nes_shm_load(&shm.pointee.front))
        lastFrameCount = nes_shm_load(&shm.pointee.frame_count)
        // `pixels` doesn't import into Swift (its bound uses that macro), so
        // locate it from the end of the struct: it is the last field.
        let pixelsOffset = MemoryLayout<nes_shm_t>.size - 2 * pixbytes
        let pixels = (UnsafeMutableRawPointer(shm)
            + pixelsOffset
            + idx * pixbytes).assumingMemoryBound(to: UInt8.self)
        guard let data = CFDataCreate(nil, pixels, pixbytes),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
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
