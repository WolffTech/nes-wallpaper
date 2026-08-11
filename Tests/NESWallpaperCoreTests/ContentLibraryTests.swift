import XCTest
@testable import NESWallpaperCore

final class ContentLibraryTests: XCTestCase {
    private var tempDir: URL!
    private var romsDir: URL!
    private var moviesDir: URL!

    override func setUpWithError() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("nes-wallpaper-tests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Canonicalize (/var -> /private/var) so fixture URLs compare equal
        // to what directory enumeration returns.
        let canonical = try XCTUnwrap(
            raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        tempDir = URL(fileURLWithPath: canonical, isDirectory: true)
        romsDir = tempDir.appendingPathComponent("roms")
        moviesDir = tempDir.appendingPathComponent("movies")
        for dir in [romsDir!, moviesDir!] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures (shared builders live in Fixtures.swift)

    private func makeROMData(seed: UInt8, payloadSize: Int = 4096) -> Data {
        Fixtures.makeROMData(seed: seed, payloadSize: payloadSize)
    }

    private func checksum(of romData: Data) -> Data {
        Fixtures.checksum(of: romData)
    }

    private func writeROM(named name: String, seed: UInt8) throws -> (url: URL, checksum: Data) {
        let data = makeROMData(seed: seed)
        let url = romsDir.appendingPathComponent(name)
        try data.write(to: url)
        return (url, checksum(of: data))
    }

    private func writeFM2(named name: String, checksumLine: String?, frames: Int,
                          romFilename: String = "fixture") throws -> URL {
        let text = Fixtures.fm2Text(checksumLine: checksumLine, frames: frames,
                                    romFilename: romFilename)
        let url = moviesDir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func base64Line(_ checksum: Data) -> String {
        Fixtures.base64Line(checksum)
    }

    // MARK: - FM2Header

    func testHeaderParsing() throws {
        let checksum = self.checksum(of: makeROMData(seed: 1))
        let url = try writeFM2(named: "a.fm2", checksumLine: Self.base64Line(checksum),
                               frames: 7, romFilename: "Some Game")
        let header = try FM2Header.parse(fileURL: url)
        XCTAssertEqual(header.romFilename, "Some Game")
        XCTAssertEqual(header.romChecksum, checksum)
        XCTAssertEqual(header.frameCount, 7)
        XCTAssertEqual(header.port0, 1)
        XCTAssertEqual(header.port1, 1)
        XCTAssertFalse(header.palFlag)
        XCTAssertFalse(header.newPPU)
    }

    func testHeaderWithMissingChecksumIsEmpty() throws {
        let url = try writeFM2(named: "a.fm2", checksumLine: nil, frames: 3)
        let header = try FM2Header.parse(fileURL: url)
        XCTAssertTrue(header.romChecksum.isEmpty)
        XCTAssertEqual(header.frameCount, 3)
    }

    func testHeaderWithGarbageChecksumIsEmpty() throws {
        let url = try writeFM2(named: "a.fm2", checksumLine: "base64:!!!not-base64!!!",
                               frames: 2)
        let header = try FM2Header.parse(fileURL: url)
        XCTAssertTrue(header.romChecksum.isEmpty)
    }

    func testHeaderHexChecksum() throws {
        let checksum = self.checksum(of: makeROMData(seed: 9))
        let hex = checksum.map { String(format: "%02x", $0) }.joined()
        let url = try writeFM2(named: "a.fm2", checksumLine: hex, frames: 1)
        let header = try FM2Header.parse(fileURL: url)
        XCTAssertEqual(header.romChecksum, checksum)
    }

    func testParseMissingFileThrows() {
        let missing = moviesDir.appendingPathComponent("nope.fm2")
        XCTAssertThrowsError(try FM2Header.parse(fileURL: missing))
    }

    // MARK: - ContentLibrary matching

    func testChecksumMatchingPicksRightROM() throws {
        _ = try writeROM(named: "a.nes", seed: 1)
        let b = try writeROM(named: "b.nes", seed: 2)
        _ = try writeROM(named: "c.nes", seed: 3)
        let movie = try writeFM2(named: "b-run.fm2",
                                 checksumLine: Self.base64Line(b.checksum), frames: 5)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertEqual(library.matches.count, 1)
        XCTAssertTrue(library.unmatched.isEmpty)
        let match = try XCTUnwrap(library.matches.first)
        XCTAssertEqual(match.romURL, b.url)
        XCTAssertEqual(match.movieURL, movie)
        XCTAssertEqual(match.frameCount, 5)
        XCTAssertEqual(match.displayName, "b-run")
        XCTAssertEqual(library.randomMatch()?.movieURL, movie)
    }

    func testHexChecksumFallbackMatches() throws {
        let rom = try writeROM(named: "a.nes", seed: 4)
        let hex = rom.checksum.map { String(format: "%02X", $0) }.joined()
        _ = try writeFM2(named: "a-run.fm2", checksumLine: hex, frames: 2)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertEqual(library.matches.count, 1)
        XCTAssertEqual(library.matches.first?.romURL, rom.url)
    }

    func testUnmatchedMovieWithUnknownChecksum() throws {
        _ = try writeROM(named: "a.nes", seed: 1)
        let orphanChecksum = checksum(of: makeROMData(seed: 200))
        let movie = try writeFM2(named: "orphan.fm2",
                                 checksumLine: Self.base64Line(orphanChecksum), frames: 4)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertTrue(library.matches.isEmpty)
        XCTAssertEqual(library.unmatched, [movie])
        XCTAssertNil(library.randomMatch())
    }

    func testUnmatchedMovieWithNoChecksum() throws {
        _ = try writeROM(named: "a.nes", seed: 1)
        let movie = try writeFM2(named: "nochecksum.fm2", checksumLine: nil, frames: 4)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertTrue(library.matches.isEmpty)
        XCTAssertEqual(library.unmatched, [movie])
    }

    func testFileWithoutNESMagicIsSkipped() throws {
        // A .nes file with no "NES\x1a" magic must not be hashed, so a movie
        // whose checksum would otherwise match its payload stays unmatched.
        var fake = Data("XXXX".utf8)
        fake.append(Data(repeating: 0, count: 12))
        fake.append(Data(repeating: 0xAB, count: 1024))
        try fake.write(to: romsDir.appendingPathComponent("fake.nes"))
        // Too-short file is skipped too, not crashed on.
        try Data([0x4E, 0x45]).write(to: romsDir.appendingPathComponent("short.nes"))

        let movie = try writeFM2(named: "fake-run.fm2",
                                 checksumLine: Self.base64Line(checksum(of: fake)), frames: 1)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertTrue(library.matches.isEmpty)
        XCTAssertEqual(library.unmatched, [movie])
    }

    func testEmptyAndMissingDirectories() throws {
        let empty = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertTrue(empty.unmatched.isEmpty)
        XCTAssertNil(empty.randomMatch())

        let missingDir = tempDir.appendingPathComponent("does-not-exist")
        let missing = ContentLibrary(romsDir: missingDir, moviesDir: missingDir)
        XCTAssertTrue(missing.matches.isEmpty)
        XCTAssertTrue(missing.unmatched.isEmpty)
    }

    func testUppercaseExtensionIsIncluded() throws {
        let rom = try writeROM(named: "loud.nes", seed: 5)
        let renamed = romsDir.appendingPathComponent("LOUD.NES")
        try FileManager.default.moveItem(at: rom.url, to: renamed)
        _ = try writeFM2(named: "loud.fm2", checksumLine: Self.base64Line(rom.checksum),
                         frames: 1)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertEqual(library.matches.first?.romURL, renamed)
    }

    // MARK: - ROMs without movies

    func testTracksROMsWithoutMovies() throws {
        let matched = try writeROM(named: "matched.nes", seed: 1)
        let lonely = try writeROM(named: "lonely.nes", seed: 2)
        _ = try writeFM2(named: "matched-run.fm2",
                         checksumLine: Self.base64Line(matched.checksum), frames: 5)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertEqual(library.matches.count, 1)
        XCTAssertEqual(library.romsWithoutMovies, [lonely.url])
    }

    func testNonINESFileIsNotAROMWithoutMovie() throws {
        var fake = Data("XXXX".utf8)
        fake.append(Data(repeating: 0xAB, count: 1024))
        try fake.write(to: romsDir.appendingPathComponent("fake.nes"))

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertTrue(library.romsWithoutMovies.isEmpty)
    }

    func testRandomTileSpecExcludesROMsWhenFlagIsOff() throws {
        _ = try writeROM(named: "lonely.nes", seed: 3)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertNil(library.randomTileSpec(includeROMsWithoutMovies: false))

        let spec = try XCTUnwrap(library.randomTileSpec(includeROMsWithoutMovies: true))
        XCTAssertEqual(spec.rom, romsDir.appendingPathComponent("lonely.nes").path)
        XCTAssertNil(spec.movie)
        XCTAssertEqual(spec.startFrame, 0)
    }

    func testRandomTileSpecWithOnlyMatchesIgnoresFlag() throws {
        let rom = try writeROM(named: "a.nes", seed: 4)
        let movie = try writeFM2(named: "a-run.fm2",
                                 checksumLine: Self.base64Line(rom.checksum), frames: 100)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        for include in [true, false] {
            let spec = try XCTUnwrap(library.randomTileSpec(includeROMsWithoutMovies: include))
            XCTAssertEqual(spec.rom, rom.url.path)
            XCTAssertEqual(spec.movie, movie.path)
            XCTAssertTrue((0...70).contains(spec.startFrame)) // first 70% of 100
        }
    }

    func testRandomTileSpecEmptyLibraryIsNil() {
        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        XCTAssertNil(library.randomTileSpec(includeROMsWithoutMovies: true))
    }

    func testRandomTileSpecMixesMatchesAndROMs() throws {
        // With one match and one movie-less ROM, both should show up across
        // repeated picks (probability of missing one in 100 draws ≈ 2^-100).
        let matched = try writeROM(named: "matched.nes", seed: 5)
        _ = try writeROM(named: "lonely.nes", seed: 6)
        _ = try writeFM2(named: "matched-run.fm2",
                         checksumLine: Self.base64Line(matched.checksum), frames: 5)

        let library = ContentLibrary(romsDir: romsDir, moviesDir: moviesDir)
        var sawMovie = false
        var sawMovieless = false
        for _ in 0..<100 {
            let spec = try XCTUnwrap(library.randomTileSpec(includeROMsWithoutMovies: true))
            if spec.movie == nil { sawMovieless = true } else { sawMovie = true }
        }
        XCTAssertTrue(sawMovie)
        XCTAssertTrue(sawMovieless)
    }

    // MARK: - Real checked-in fixture

    private var testDataDir: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/NESWallpaperCoreTests/ContentLibraryTests.swift
            .deletingLastPathComponent()         // .../Tests/NESWallpaperCoreTests
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("TestData")
    }

    func testRealNestestHeaderMatchesROM() throws {
        let fm2URL = testDataDir.appendingPathComponent("nestest.fm2")
        let romURL = testDataDir.appendingPathComponent("nestest.nes")

        let header = try FM2Header.parse(fileURL: fm2URL)
        XCTAssertEqual(header.romFilename, "nestest")
        XCTAssertEqual(header.romChecksum.count, 16)

        let romData = try Data(contentsOf: romURL)
        XCTAssertEqual(header.romChecksum, checksum(of: romData))

        // Independent frame count: lines starting with '|'.
        let text = try String(contentsOf: fm2URL, encoding: .utf8)
        let expected = text.split(separator: "\n").filter { $0.hasPrefix("|") }.count
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(header.frameCount, expected)
    }

    func testRealNestestLibraryMatch() throws {
        // TestData holds both the ROM and the movie; use it for both scans.
        let library = ContentLibrary(romsDir: testDataDir, moviesDir: testDataDir)
        XCTAssertEqual(library.matches.count, 1)
        let match = try XCTUnwrap(library.matches.first)
        XCTAssertEqual(match.romURL.lastPathComponent, "nestest.nes")
        XCTAssertEqual(match.movieURL.lastPathComponent, "nestest.fm2")
        XCTAssertEqual(match.displayName, "nestest")
        XCTAssertGreaterThan(match.frameCount, 0)
        XCTAssertTrue(library.unmatched.isEmpty)
    }
}
