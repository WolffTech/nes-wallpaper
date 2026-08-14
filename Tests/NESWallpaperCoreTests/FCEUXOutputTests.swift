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
}
