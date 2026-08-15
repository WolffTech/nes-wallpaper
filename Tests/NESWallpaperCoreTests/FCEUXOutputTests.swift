// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import XCTest
import CFCEUX

final class FCEUXOutputTests: XCTestCase {
    private var testDataDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestData")
    }

    private func saveState() throws -> Data {
        let size = Int(fceux_state_save(nil, 0))
        XCTAssertGreaterThan(size, 0)
        var data = Data(count: size)
        let written = data.withUnsafeMutableBytes { bytes in
            fceux_state_save(bytes.bindMemory(to: UInt8.self).baseAddress, size)
        }
        XCTAssertEqual(Int(written), size)
        return data
    }

    private func loadState(_ data: Data) {
        let loaded = data.withUnsafeBytes { bytes in
            fceux_state_load(bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        XCTAssertEqual(loaded, 1)
    }

    func testDirectOutputMatchesInternalBufferAndNoOutputModeIsExact() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("fceux-output-tests.\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        XCTAssertNotEqual(fceux_init(support.path), 0)
        let rom = testDataDirectory.appendingPathComponent("nestest.nes")
        XCTAssertNotEqual(fceux_load_game(rom.path), 0)
        defer { fceux_close_game() }
        XCTAssertNotEqual(fceux_set_video_filter(0, 0), 0)

        let width = Int(fceux_frame_width())
        let height = Int(fceux_frame_height())
        let pitch = width * 4
        let byteCount = pitch * height
        let initialState = try saveState()

        let internalPointer = try XCTUnwrap(fceux_run_frame(0))
        let internalOutput = Data(bytes: internalPointer, count: byteCount)

        loadState(initialState)
        var directOutput = Data(count: byteCount)
        let directResult = directOutput.withUnsafeMutableBytes { bytes in
            fceux_run_frame_into(
                bytes.bindMemory(to: UInt8.self).baseAddress, Int32(pitch))
        }
        XCTAssertEqual(directResult, 1)
        XCTAssertEqual(directOutput, internalOutput)

        // Fast-forward/low-power mode must advance the same exact core state
        // as rendered frames; it skips only the wallpaper's color conversion.
        loadState(initialState)
        for _ in 0..<120 {
            XCTAssertNil(fceux_run_frame(2))
        }
        let noOutputState = try saveState()

        loadState(initialState)
        for _ in 0..<120 {
            XCTAssertNotNil(fceux_run_frame(0))
        }
        let renderedState = try saveState()
        XCTAssertEqual(noOutputState, renderedState)
    }

    // Sound is disabled by rate only and can be toggled at runtime: off by
    // default (silent wallpaper), on during live-play takeover.
    func testRuntimeSoundToggleProducesSamples() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("fceux-sound-tests.\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        XCTAssertNotEqual(fceux_init(support.path), 0)
        let rom = testDataDirectory.appendingPathComponent("nestest.nes")
        XCTAssertNotEqual(fceux_load_game(rom.path), 0)
        defer {
            fceux_set_sound_rate(0) // leave the global core silent for other tests
            fceux_close_game()
        }
        XCTAssertNotEqual(fceux_set_video_filter(0, 0), 0)

        var samples: UnsafePointer<Int32>?
        _ = fceux_run_frame(2)
        XCTAssertEqual(fceux_sound_samples(&samples), 0, "sound must be off by default")

        fceux_set_sound_rate(44100)
        var total = 0
        for _ in 0..<60 {
            _ = fceux_run_frame(2)
            let count = Int(fceux_sound_samples(&samples))
            XCTAssertGreaterThan(count, 0)
            XCTAssertNotNil(samples)
            total += count
        }
        // 60 NTSC frames at 60.0988 fps is just under one second of audio.
        XCTAssertGreaterThan(total, 42000)
        XCTAssertLessThan(total, 46000)

        fceux_set_sound_rate(0)
        _ = fceux_run_frame(2)
        XCTAssertEqual(fceux_sound_samples(&samples), 0)
    }

    // The takeover primitive: while an FM2 movie plays, the live joypad is
    // ignored entirely; fceux_stop_movie() preserves console state and the
    // live joypad drives the game from the next frame.
    func testStopMovieSwitchesToLiveJoypadInput() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("fceux-takeover-tests.\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        XCTAssertNotEqual(fceux_init(support.path), 0)
        let rom = testDataDirectory.appendingPathComponent("nestest.nes")
        let movie = testDataDirectory.appendingPathComponent("nestest.fm2")
        XCTAssertNotEqual(fceux_load_game(rom.path), 0)
        defer { fceux_close_game() }
        XCTAssertNotEqual(fceux_set_video_filter(0, 0), 0)

        let byteCount = Int(fceux_frame_width()) * 4 * Int(fceux_frame_height())
        func renderFrame() throws -> Data {
            Data(bytes: try XCTUnwrap(fceux_run_frame(0)), count: byteCount)
        }

        // nestest.fm2 presses nothing until it hits Start at frame ~124, so
        // frame 60 is the static menu with no movie input involved yet.

        // Capture playback with no live input.
        XCTAssertNotEqual(fceux_load_movie(movie.path), 0)
        XCTAssertNotEqual(fceux_movie_is_playing(), 0)
        fceux_set_joypad(0, 0)
        for _ in 0..<59 { _ = fceux_run_frame(2) }
        let playbackClean = try renderFrame()

        // It must be identical to playback with every live button held down:
        // movie playback skips the driver input poll completely.
        XCTAssertNotEqual(fceux_load_movie(movie.path), 0) // power-cycle to frame 0
        fceux_set_joypad(0, 0xFF)
        for _ in 0..<59 { _ = fceux_run_frame(2) }
        let playbackHeld = try renderFrame()
        XCTAssertEqual(playbackClean, playbackHeld,
                       "live joypad must be ignored during movie playback")

        // Take over on the menu: stop the movie in place, no power-cycle.
        fceux_set_joypad(0, 0)
        fceux_stop_movie()
        XCTAssertEqual(fceux_movie_is_playing(), 0)
        let takeoverState = try saveState()

        // With no input, the menu sits still.
        for _ in 0..<60 { _ = fceux_run_frame(2) }
        let idle = try renderFrame()

        // From the same point, holding Start launches nestest's tests.
        loadState(takeoverState)
        fceux_set_joypad(0, 0x08) // Start
        for _ in 0..<60 { _ = fceux_run_frame(2) }
        let started = try renderFrame()
        fceux_set_joypad(0, 0)

        XCTAssertNotEqual(idle, started,
                          "live joypad must drive the game after fceux_stop_movie")
    }
}
