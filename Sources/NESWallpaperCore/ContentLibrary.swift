import CryptoKit
import Foundation

/// An FM2 movie paired with the ROM it was recorded against.
public struct MatchedMovie {
    public let romURL: URL
    public let movieURL: URL
    public let frameCount: Int
    /// Movie filename without extension.
    public let displayName: String
}

/// Scans a folder of NES ROMs and a folder of FM2 movies and matches them by
/// checksum: FCEUX embeds the MD5 of the ROM bytes after the 16-byte iNES
/// header in each movie's `romChecksum` header line.
public final class ContentLibrary {
    public private(set) var matches: [MatchedMovie] = []
    /// Movies with no parseable checksum or no matching ROM.
    public private(set) var unmatched: [URL] = []
    /// Valid iNES ROMs whose checksum matched no movie; playable without a
    /// movie (no input: title/attract mode). Files that fail the iNES check
    /// are excluded entirely, same as for matching.
    public private(set) var romsWithoutMovies: [URL] = []

    public init(romsDir: URL, moviesDir: URL) {
        let romURLs = Self.files(in: romsDir, extension: "nes")
        let movieURLs = Self.files(in: moviesDir, extension: "fm2")

        // First ROM with a given checksum wins (duplicates are the same game).
        var romsByChecksum: [Data: URL] = [:]
        for romURL in romURLs {
            guard let checksum = Self.romChecksum(romURL) else { continue }
            if romsByChecksum[checksum] == nil { romsByChecksum[checksum] = romURL }
        }

        var matchedChecksums: Set<Data> = []
        for movieURL in movieURLs {
            guard let header = try? FM2Header.parse(fileURL: movieURL),
                  !header.romChecksum.isEmpty,
                  let romURL = romsByChecksum[header.romChecksum] else {
                unmatched.append(movieURL)
                continue
            }
            matchedChecksums.insert(header.romChecksum)
            matches.append(MatchedMovie(
                romURL: romURL,
                movieURL: movieURL,
                frameCount: header.frameCount,
                displayName: movieURL.deletingPathExtension().lastPathComponent))
        }

        romsWithoutMovies = romsByChecksum
            .filter { !matchedChecksums.contains($0.key) }
            .map(\.value)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        Self.log("content-library: \(romURLs.count) roms, \(movieURLs.count) movies, "
            + "\(matches.count) matched, \(romsWithoutMovies.count) roms without movies")
    }

    public func randomMatch() -> MatchedMovie? {
        matches.randomElement()
    }

    /// Uniform random pick across matched movies and, optionally, ROMs with
    /// no matching movie. Matched picks start at a random point in the first
    /// 70% of the movie; movie-less picks start at power-on with no input.
    public func randomTileSpec(includeROMsWithoutMovies: Bool) -> TileSpec? {
        let romOnlyCount = includeROMsWithoutMovies ? romsWithoutMovies.count : 0
        let total = matches.count + romOnlyCount
        guard total > 0 else { return nil }
        let index = Int.random(in: 0..<total)
        guard index < matches.count else {
            return TileSpec(rom: romsWithoutMovies[index - matches.count].path, movie: nil)
        }
        let match = matches[index]
        let maxStart = Int(Double(match.frameCount) * 0.7)
        return TileSpec(
            rom: match.romURL.path,
            movie: match.movieURL.path,
            startFrame: maxStart > 0 ? Int.random(in: 0...maxStart) : 0)
    }

    /// MD5 of the ROM bytes after the 16-byte iNES header, or nil if the file
    /// is unreadable, shorter than the header, or lacks the "NES\x1a" magic.
    static func romChecksum(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 16,
              data.prefix(4).elementsEqual([0x4E, 0x45, 0x53, 0x1A]) else { // "NES\x1a"
            return nil
        }
        return Data(Insecure.MD5.hash(data: data.dropFirst(16)))
    }

    /// Non-recursive listing of regular files with the given extension
    /// (case-insensitive), sorted by name. An unreadable directory is
    /// treated as empty.
    static func files(in directory: URL, extension ext: String) -> [URL] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            log("content-library: cannot read \(directory.path): \(error.localizedDescription)")
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
