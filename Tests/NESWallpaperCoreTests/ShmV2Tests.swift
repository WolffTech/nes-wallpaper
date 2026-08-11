import XCTest
import CShm
@testable import NESWallpaperCore

final class ShmV2Tests: XCTestCase {
    private var shmName = ""

    override func setUp() {
        super.setUp()
        // Unique per test run; must stay under the 31-char PSHMNAMLEN cap.
        shmName = "/nes.test.\(getpid())"
    }

    override func tearDown() {
        shm_unlink(shmName)
        super.tearDown()
    }

    func testCreateOpenRoundTrip() {
        guard let writer = nes_shm_create(shmName, 602, 480) else {
            XCTFail("create failed"); return
        }
        defer { nes_shm_close(writer, shmName, 1) }

        XCTAssertEqual(writer.pointee.width, 602)
        XCTAssertEqual(writer.pointee.height, 480)
        XCTAssertEqual(writer.pointee.pitch, 602 * 4)

        guard let reader = nes_shm_open(shmName) else {
            XCTFail("open failed"); return
        }
        defer { nes_shm_close(reader, shmName, 0) }

        XCTAssertEqual(reader.pointee.version, 2)
        XCTAssertEqual(reader.pointee.width, 602)
        XCTAssertEqual(reader.pointee.height, 480)

        // Buffers are adjacent, each width*height*4 bytes.
        let stride = nes_shm_pixels(writer, 1) - nes_shm_pixels(writer, 0)
        XCTAssertEqual(stride, 602 * 480 * 4)

        // Writes land in the mapping the reader sees, including the very
        // last byte of buffer 1 (bounds check on the segment size).
        let last = Int(nes_shm_pix_bytes(602, 480)) - 1
        nes_shm_pixels(writer, 1)[last] = 0xAB
        XCTAssertEqual(nes_shm_pixels(reader, 1)[last], 0xAB)
    }

    func testCreateRejectsOversizedDimensions() {
        XCTAssertNil(nes_shm_create(shmName, 769, 480))
        XCTAssertNil(nes_shm_create(shmName, 256, 721))
        XCTAssertNil(nes_shm_create(shmName, 0, 240))
    }

    func testOpenRejectsCorruptHeader() {
        guard let writer = nes_shm_create(shmName, 256, 240) else {
            XCTFail("create failed"); return
        }
        // A header whose dimensions disagree with the segment size (or whose
        // pitch is wrong) must be refused, not mapped short.
        writer.pointee.width = 300 // pitch and total size now both wrong
        XCTAssertNil(nes_shm_open(shmName))

        writer.pointee.width = 256
        writer.pointee.pitch = 999
        XCTAssertNil(nes_shm_open(shmName))

        writer.pointee.pitch = 256 * 4
        XCTAssertNotNil(nes_shm_open(shmName)) // restored: opens again
        nes_shm_close(writer, shmName, 1)
    }

    /// The sizes the app allocates textures from must match what the shim's
    /// fceux_set_video_filter emits (and nes-helper publishes) per filter.
    func testVideoFilterOutputSizes() {
        let expected: [VideoFilter: (Int, Int)] = [
            .none: (256, 240),
            .hq2x: (512, 480), .scale2x: (512, 480),
            .ntscComposite: (602, 480), .ntscSVideo: (602, 480),
            .ntscRGB: (602, 480), .ntscMono: (602, 480),
            .hq3x: (768, 720), .scale3x: (768, 720),
        ]
        XCTAssertEqual(expected.count, VideoFilter.allCases.count)
        for filter in VideoFilter.allCases {
            XCTAssertNotNil(expected[filter])
            XCTAssertEqual(filter.outputSize.width, expected[filter]?.0, "\(filter)")
            XCTAssertEqual(filter.outputSize.height, expected[filter]?.1, "\(filter)")
            // Every filter must fit the shm bounds.
            XCTAssertLessThanOrEqual(filter.outputSize.width, 768)
            XCTAssertLessThanOrEqual(filter.outputSize.height, 720)
        }
    }
}
