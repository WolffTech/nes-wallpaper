// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import NESWallpaperCore

/// Hits the real tasvideos.org API; skipped unless TASVIDEOS_LIVE=1 so normal
/// runs stay offline. Run with:
///   TASVIDEOS_LIVE=1 swift test --filter LiveTASVideosTests
final class LiveTASVideosTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TASVIDEOS_LIVE"] == "1",
                          "set TASVIDEOS_LIVE=1 to run live API tests")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nes-wallpaper-live.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try FileManager.default.removeItem(at: tempDir) }
    }

    func testFetchCatalogAndInstallOneMovie() async throws {
        let client = TASVideosClient()
        let all = try await client.fetchAllNESPublications()
        let playable = TASPublication.playable(all)
        XCTAssertGreaterThan(playable.count, 300) // ~464 as of 2026-08

        // Movie file names double as the install key; the catalog must keep
        // them unique for that to hold.
        XCTAssertEqual(Set(playable.map(\.movieFileName)).count, playable.count)

        // Pick the shortest run to keep the download tiny, preferring a
        // Mega Man run when the local test ROM is present.
        let romsDir = tempDir.appendingPathComponent("roms")
        let moviesDir = tempDir.appendingPathComponent("movies")
        for dir in [romsDir, moviesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let localROM = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("temp/Mega Man.nes")
        var candidates = playable
        if FileManager.default.fileExists(atPath: localROM.path) {
            try FileManager.default.copyItem(
                at: localROM, to: romsDir.appendingPathComponent("Mega Man.nes"))
            let megaMan = playable.filter { $0.title.localizedCaseInsensitiveContains("mega man") }
            if !megaMan.isEmpty { candidates = megaMan }
        }
        let pick = candidates.min { $0.frames < $1.frames }!

        let outcome = try await MovieInstaller().install(
            publication: pick, moviesDir: moviesDir, romsDir: romsDir)
        let movieURL = moviesDir.appendingPathComponent(pick.movieFileName)
        switch outcome {
        case .ready(let url), .missingROM(let url):
            XCTAssertEqual(url, movieURL)
        }
        print("live test: installed \(pick.title) -> \(outcome)")

        let header = try FM2Header.parse(fileURL: movieURL)
        XCTAssertGreaterThan(header.frameCount, 0)
        XCTAssertEqual(MovieInstaller.installedFileNames(in: moviesDir),
                       [pick.movieFileName])
    }
}
