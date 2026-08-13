import Foundation

/// Filesystem layout shared between the wallpaper app (writer side) and the
/// screensaver plugin (reader side). Everything lives under /Users/Shared
/// because that is the one location the sandboxed legacyScreenSaver host can
/// read without TCC consent; the saver never needs write access here.
public enum SharedFrames {
    public static let baseDirectory = URL(
        fileURLWithPath: "/Users/Shared/NESWallpaper", isDirectory: true)
    public static let tilesDirectory = baseDirectory
        .appendingPathComponent("tiles", isDirectory: true)

    /// Frame file for one helper. The owning app's pid is embedded so stale
    /// files from a crashed app can be identified and reclaimed.
    public static func tileURL(pid: pid_t, counter: Int) -> URL {
        tilesDirectory.appendingPathComponent("nes.\(pid).\(counter).frame")
    }

    /// Create the tiles directory and remove frame files left behind by app
    /// instances that are no longer running. Live files are untouched: a
    /// second app instance (e.g. a dev build) keeps its tiles.
    public static func prepareTilesDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tilesDirectory, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(
            at: tilesDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            guard let pid = ownerPid(of: entry.lastPathComponent) else { continue }
            // kill(pid, 0) probes liveness; ESRCH means the owner is gone.
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Parses "nes.<pid>.<counter>.frame"; nil for anything else.
    static func ownerPid(of fileName: String) -> pid_t? {
        let parts = fileName.split(separator: ".")
        guard parts.count == 4, parts[0] == "nes", parts[3] == "frame",
              let pid = pid_t(parts[1]), Int(parts[2]) != nil else { return nil }
        return pid
    }

    // MARK: - Manifest (app writes, saver reads)

    /// What the saver needs to reproduce the grid: the frame file for every
    /// tile slot, in grid order (row-major, matching TileGridRenderer). A
    /// dead tile's path stays listed; its file is gone, and readers render
    /// that slot black — same as the wallpaper does.
    public struct Manifest: Codable, Equatable {
        public let version: Int
        public let pid: Int32
        public let columns: Int
        public let rows: Int
        /// Frame size shared by every tile this run (fixed per video filter),
        /// so a reader can size its textures before any tile file is mapped.
        public let tileWidth: Int
        public let tileHeight: Int
        public let tiles: [String]

        public init(pid: Int32, columns: Int, rows: Int,
                    tileWidth: Int, tileHeight: Int, tiles: [String]) {
            self.version = 1
            self.pid = pid
            self.columns = columns
            self.rows = rows
            self.tileWidth = tileWidth
            self.tileHeight = tileHeight
            self.tiles = tiles
        }
    }

    public static let manifestURL = baseDirectory
        .appendingPathComponent("manifest.json")

    /// Atomic (write-then-rename), so readers never see a torn manifest.
    public static func write(_ manifest: Manifest, to url: URL = manifestURL) throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    public static func readManifest(from url: URL = manifestURL) -> Manifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1 else { return nil }
        return manifest
    }

    // MARK: - Heartbeat (saver writes, app reads)

    /// The saver can only write inside the legacyScreenSaver container, so
    /// the heartbeat lives there. Both sides build the path from their own
    /// notion of "home": for the sandboxed saver that already *is* the
    /// container's Data directory, for the app it is grafted on below.
    public static func heartbeatURL(home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Application Support/NESWallpaper/heartbeat")
    }

    /// Where the app finds the saver's heartbeat.
    public static var appSideHeartbeatURL: URL {
        heartbeatURL(home: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data",
                isDirectory: true))
    }

    /// A heartbeat is fresh while its mtime is recent. The saver touches the
    /// file about once a second; the generous window rides out scheduling
    /// stalls without letting emulation run long after the saver is gone.
    public static func heartbeatFresh(
        at url: URL, now: Date = Date(), maxAge: TimeInterval = 4
    ) -> Bool {
        guard let mtime = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        // abs(): an mtime in the future is clock skew, not a live saver.
        return abs(now.timeIntervalSince(mtime)) <= maxAge
    }
}
