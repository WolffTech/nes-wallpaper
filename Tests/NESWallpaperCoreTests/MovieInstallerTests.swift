import XCTest
@testable import NESWallpaperCore

final class MovieInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var romsDir: URL!
    private var moviesDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nes-wallpaper-tests.\(UUID().uuidString)")
        romsDir = tempDir.appendingPathComponent("roms")
        moviesDir = tempDir.appendingPathComponent("movies")
        for dir in [tempDir!, romsDir!, moviesDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    /// Builds a real zip archive with `/usr/bin/zip -j` (ships with macOS),
    /// mirroring what tasvideos.org serves.
    private func makeZip(files: [String: Data]) throws -> Data {
        let stagingDir = tempDir.appendingPathComponent("zip-staging.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: stagingDir.appendingPathComponent(name))
        }
        let zipURL = stagingDir.appendingPathComponent("archive.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-q", zipURL.path]
            + files.keys.map { stagingDir.appendingPathComponent($0).path }
        process.currentDirectoryURL = stagingDir
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zipURL)
    }

    private func makePublication(movieFileName: String) -> TASPublication {
        TASPublication(id: 42, title: "NES Game by a", movieFileName: movieFileName,
                       frames: 3, systemFrameRate: 60, authors: ["a"],
                       obsoletedById: nil, publicationClass: "Standard", urls: [])
    }

    // MARK: - extractFM2

    func testExtractFM2ReturnsNameAndBytes() throws {
        let fm2 = Data(Fixtures.fm2Text(checksumLine: nil, frames: 3).utf8)
        let zip = try makeZip(files: ["run.fm2": fm2, "readme.txt": Data("hi".utf8)])
        let extracted = try MovieInstaller.extractFM2(fromZipData: zip)
        XCTAssertEqual(extracted.fileName, "run.fm2")
        XCTAssertEqual(extracted.data, fm2)
    }

    func testExtractFM2ThrowsWhenArchiveHasNoFM2() throws {
        let zip = try makeZip(files: ["readme.txt": Data("hi".utf8)])
        XCTAssertThrowsError(try MovieInstaller.extractFM2(fromZipData: zip)) { error in
            guard case MovieInstaller.InstallError.noFM2InArchive = error else {
                return XCTFail("expected noFM2InArchive, got \(error)")
            }
        }
    }

    func testExtractFM2ThrowsOnGarbageBytes() {
        let garbage = Data((0..<256).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertThrowsError(try MovieInstaller.extractFM2(fromZipData: garbage)) { error in
            guard case MovieInstaller.InstallError.unzipFailed = error else {
                return XCTFail("expected unzipFailed, got \(error)")
            }
        }
    }

    // MARK: - install

    func testInstallWithMatchingROMIsReady() async throws {
        let romData = Fixtures.makeROMData(seed: 7)
        try romData.write(to: romsDir.appendingPathComponent("game.nes"))
        let checksumLine = Fixtures.base64Line(Fixtures.checksum(of: romData))
        let fm2 = Data(Fixtures.fm2Text(checksumLine: checksumLine, frames: 5).utf8)

        let transport = StubTransport()
        transport.enqueue(data: try makeZip(files: ["a-run.fm2": fm2]))

        let outcome = try await MovieInstaller(transport: transport).install(
            publication: makePublication(movieFileName: "a-run.fm2"),
            moviesDir: moviesDir, romsDir: romsDir)

        let movieURL = moviesDir.appendingPathComponent("a-run.fm2")
        XCTAssertEqual(outcome, .ready(movieURL: movieURL))
        XCTAssertEqual(try Data(contentsOf: movieURL), fm2)
    }

    func testInstallWithoutMatchingROMIsMissingROM() async throws {
        let orphanChecksum = Fixtures.checksum(of: Fixtures.makeROMData(seed: 200))
        let fm2 = Data(Fixtures.fm2Text(
            checksumLine: Fixtures.base64Line(orphanChecksum), frames: 5).utf8)

        let transport = StubTransport()
        transport.enqueue(data: try makeZip(files: ["b-run.fm2": fm2]))

        let outcome = try await MovieInstaller(transport: transport).install(
            publication: makePublication(movieFileName: "b-run.fm2"),
            moviesDir: moviesDir, romsDir: romsDir)
        XCTAssertEqual(outcome,
                       .missingROM(movieURL: moviesDir.appendingPathComponent("b-run.fm2")))
    }

    func testInstallOverwritesExistingFile() async throws {
        let movieURL = moviesDir.appendingPathComponent("c-run.fm2")
        try Data("stale".utf8).write(to: movieURL)

        let fm2 = Data(Fixtures.fm2Text(checksumLine: nil, frames: 2).utf8)
        let transport = StubTransport()
        transport.enqueue(data: try makeZip(files: ["c-run.fm2": fm2]))

        _ = try await MovieInstaller(transport: transport).install(
            publication: makePublication(movieFileName: "c-run.fm2"),
            moviesDir: moviesDir, romsDir: romsDir)
        XCTAssertEqual(try Data(contentsOf: movieURL), fm2)
    }

    func testInstallUsesAPIFileNameOverArchiveMemberName() async throws {
        let fm2 = Data(Fixtures.fm2Text(checksumLine: nil, frames: 1).utf8)
        let transport = StubTransport()
        transport.enqueue(data: try makeZip(files: ["inner-name.fm2": fm2]))

        let outcome = try await MovieInstaller(transport: transport).install(
            publication: makePublication(movieFileName: "canonical.fm2"),
            moviesDir: moviesDir, romsDir: romsDir)
        XCTAssertEqual(outcome,
                       .missingROM(movieURL: moviesDir.appendingPathComponent("canonical.fm2")))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moviesDir.appendingPathComponent("canonical.fm2").path))
    }

    // MARK: - installedFileNames

    func testInstalledFileNamesListsOnlyFM2s() throws {
        try Data("a".utf8).write(to: moviesDir.appendingPathComponent("one.fm2"))
        try Data("b".utf8).write(to: moviesDir.appendingPathComponent("TWO.FM2"))
        try Data("c".utf8).write(to: moviesDir.appendingPathComponent("not-a-movie.txt"))
        XCTAssertEqual(MovieInstaller.installedFileNames(in: moviesDir),
                       ["one.fm2", "TWO.FM2"])
    }
}
