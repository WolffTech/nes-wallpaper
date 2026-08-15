// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import XCTest
@testable import NESWallpaperCore

/// End-to-end takeover over the real control surfaces: spawns the built
/// nes-helper, drives it through TileProcess's stdin commands, and observes
/// the shared frame file — the same channels the wallpaper app uses.
final class HelperTakeoverTests: XCTestCase {
    private var testDataDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestData")
    }

    /// swift test builds executables into the same products directory the
    /// test bundle lives in.
    private var helperURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("nes-helper")
    }

    private func waitUntil(
        timeout: TimeInterval, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    func testTakeoverInputAndReleaseOverStdin() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helperURL.path),
            "nes-helper not built next to the test bundle")

        let shmName = NSTemporaryDirectory() + "nes.takeover.\(getpid()).frame"
        defer { unlink(shmName) }

        let tile = try TileProcess(
            helper: helperURL, shmName: shmName,
            rom: testDataDirectory.appendingPathComponent("nestest.nes").path,
            movie: testDataDirectory.appendingPathComponent("nestest.fm2").path,
            loop: true)
        defer { tile.terminate() }

        XCTAssertTrue(tile.openSharedMemory(timeout: 10), "helper never published")
        XCTAssertTrue(waitUntil(timeout: 5) { tile.frameCount > 0 && tile.moviePlaying },
                      "movie playback never started")

        func snapshot() throws -> Data {
            let size = try XCTUnwrap(tile.frameSize)
            let taken = tile.withFrontBuffer { pixels, bytesPerRow in
                Data(bytes: pixels, count: bytesPerRow * size.height)
            }
            return try XCTUnwrap(taken).result
        }

        // Takeover stops playback but the tile keeps emulating and publishing.
        tile.beginTakeover()
        XCTAssertTrue(waitUntil(timeout: 3) { !tile.moviePlaying },
                      "takeover did not stop movie playback")
        let countAtTakeover = tile.frameCount
        XCTAssertTrue(waitUntil(timeout: 3) { tile.frameCount > countAtTakeover &+ 5 },
                      "tile stopped publishing after takeover")

        // Live input reaches the game: nestest sits on its static menu until
        // Start is held, which launches its test run and changes the screen.
        let menu = try snapshot()
        tile.sendInput(.start)
        XCTAssertTrue(waitUntil(timeout: 5) { (try? snapshot()) != menu },
                      "held Start never changed the screen")
        tile.sendInput([])

        // Release hands the tile back: the looped movie restarts from frame 0.
        tile.endTakeover()
        XCTAssertTrue(waitUntil(timeout: 3) { tile.moviePlaying },
                      "release did not restart movie playback")
    }
}
