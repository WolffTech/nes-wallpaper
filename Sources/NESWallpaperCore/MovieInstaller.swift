// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Downloads a publication's movie archive, extracts the FM2, installs it
/// into the movies folder, and reports whether a matching ROM is present.
public struct MovieInstaller {
    public enum Outcome: Equatable, Sendable {
        /// FM2 installed and a ROM with its checksum exists in the ROM folder.
        case ready(movieURL: URL)
        /// FM2 installed but no ROM matches its checksum (or it has none).
        case missingROM(movieURL: URL)
    }

    public enum InstallError: Error, LocalizedError {
        case unzipFailed(status: Int32, message: String)
        case noFM2InArchive
        case writeFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Could not extract the downloaded archive."
            case .noFM2InArchive: return "The downloaded archive contains no FM2 movie."
            case .writeFailed(let error):
                return "Could not save the movie: \(error.localizedDescription)"
            }
        }
    }

    private let client: TASVideosClient

    public init(transport: HTTPTransport = URLSession.shared) {
        client = TASVideosClient(transport: transport)
    }

    /// Download → extract → write `moviesDir/<movieFileName>` (overwriting, so
    /// a re-download is a refresh) → checksum-match against `romsDir`.
    public func install(publication: TASPublication,
                        moviesDir: URL, romsDir: URL) async throws -> Outcome {
        let archive = try await client.downloadMovieArchive(publicationID: publication.id)
        let extracted = try Self.extractFM2(fromZipData: archive)
        // Install under the API's canonical name — install-state detection
        // keys on it — and note the (never yet observed) mismatch case.
        if extracted.fileName != publication.movieFileName {
            log("archive file \(extracted.fileName) != api name \(publication.movieFileName)")
        }
        let movieURL = moviesDir.appendingPathComponent(publication.movieFileName)
        do {
            try extracted.data.write(to: movieURL, options: [.atomic])
        } catch {
            throw InstallError.writeFailed(error)
        }
        let header = FM2Header.parse(data: extracted.data)
        let hasROM = !header.romChecksum.isEmpty
            && Self.romChecksums(in: romsDir).contains(header.romChecksum)
        return hasROM ? .ready(movieURL: movieURL) : .missingROM(movieURL: movieURL)
    }

    /// Unzips into a private temp directory via `/usr/bin/ditto -x -k` and
    /// returns the first `.fm2` member (name and contents).
    static func extractFM2(fromZipData data: Data) throws -> (fileName: String, data: Data) {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nes-wallpaper.\(UUID().uuidString)")
        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent("movie.zip")
        try data.write(to: zipURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, outDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unzipFailed(
                status: process.terminationStatus,
                message: String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let enumerator = FileManager.default.enumerator(
            at: outDir, includingPropertiesForKeys: [.isRegularFileKey])
        while let entry = enumerator?.nextObject() as? URL {
            guard entry.pathExtension.lowercased() == "fm2",
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?
                      .isRegularFile == true else { continue }
            return (entry.lastPathComponent, try Data(contentsOf: entry))
        }
        throw InstallError.noFM2InArchive
    }

    /// Checksums of every valid iNES ROM in the folder.
    static func romChecksums(in romsDir: URL) -> Set<Data> {
        Set(ContentLibrary.files(in: romsDir, extension: "nes")
            .compactMap(ContentLibrary.romChecksum))
    }

    /// Names of the FM2 files already in the movies folder, for marking
    /// catalog rows as installed.
    public static func installedFileNames(in moviesDir: URL) -> Set<String> {
        Set(ContentLibrary.files(in: moviesDir, extension: "fm2")
            .map { $0.lastPathComponent })
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("movie-installer: \(message)\n".utf8))
    }
}
