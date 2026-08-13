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
}
