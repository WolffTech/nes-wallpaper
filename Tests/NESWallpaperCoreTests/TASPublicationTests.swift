import XCTest
@testable import NESWallpaperCore

final class TASPublicationTests: XCTestCase {
    private func makePub(id: Int = 1, title: String = "NES Game by someone",
                         movieFileName: String = "run.fm2", frames: Int = 3600,
                         systemFrameRate: Double = 60.0988, authors: [String] = ["someone"],
                         obsoletedById: Int? = nil, publicationClass: String? = "Standard",
                         urls: [String] = []) -> TASPublication {
        TASPublication(id: id, title: title, movieFileName: movieFileName,
                       frames: frames, systemFrameRate: systemFrameRate,
                       authors: authors, obsoletedById: obsoletedById,
                       publicationClass: publicationClass, urls: urls)
    }

    // MARK: - Decoding

    func testDecodesRealShapedJSON() throws {
        // Field shapes as served by the live API, including keys the model
        // ignores and the `class` keyword mapping.
        let json = """
        {
            "id": 122,
            "title": "NES Snake Rattle 'n' Roll \\"warps, 1 player\\" by devindotcom in 05:08.433",
            "branch": "warps, 1 player",
            "class": "Standard",
            "systemCode": "NES",
            "obsoletedById": null,
            "frames": 18506,
            "rerecordCount": 708,
            "systemFrameRate": 60.0988138974405,
            "movieFileName": "devin-snakroll-warps.fm2",
            "additionalAuthors": null,
            "authors": ["devindotcom"],
            "tags": ["just1p", "warps"],
            "urls": [
                "https://archive.org/download/foo/foo.mp4",
                "https://www.youtube.com/watch?v=Qjn_FfcHevE"
            ]
        }
        """
        let pub = try JSONDecoder().decode(TASPublication.self, from: Data(json.utf8))
        XCTAssertEqual(pub.id, 122)
        XCTAssertEqual(pub.movieFileName, "devin-snakroll-warps.fm2")
        XCTAssertEqual(pub.frames, 18506)
        XCTAssertEqual(pub.authors, ["devindotcom"])
        XCTAssertNil(pub.obsoletedById)
        XCTAssertEqual(pub.publicationClass, "Standard")
        XCTAssertEqual(pub.urls.count, 2)
        XCTAssertEqual(pub.youtubeURL?.absoluteString,
                       "https://www.youtube.com/watch?v=Qjn_FfcHevE")
    }

    func testDecodesLenientlyWhenOptionalShapesSurprise() throws {
        // Unexpected element types in authors/urls must not sink the decode.
        let json = """
        {
            "id": 5,
            "title": "NES Something",
            "movieFileName": "x.fm2",
            "frames": 100,
            "systemFrameRate": 60,
            "authors": [{"name": "weird"}],
            "urls": null
        }
        """
        let pub = try JSONDecoder().decode(TASPublication.self, from: Data(json.utf8))
        XCTAssertEqual(pub.authors, [])
        XCTAssertEqual(pub.urls, [])
        XCTAssertNil(pub.publicationClass)
    }

    func testEncodeDecodeRoundtrip() throws {
        let pub = makePub(obsoletedById: 9, urls: ["https://youtu.be/abc"])
        let data = try JSONEncoder().encode(pub)
        let decoded = try JSONDecoder().decode(TASPublication.self, from: data)
        XCTAssertEqual(decoded, pub)
    }

    // MARK: - Filtering and search

    func testPlayableFiltersFormatsAndObsoleted() {
        let pubs = [
            makePub(id: 1, title: "B game", movieFileName: "b.fm2"),
            makePub(id: 2, title: "Bizhawk run", movieFileName: "run.bk2"),
            makePub(id: 3, title: "Old fceu run", movieFileName: "old.fcm"),
            makePub(id: 4, title: "A game", movieFileName: "a.FM2"),
            makePub(id: 5, title: "Obsoleted", movieFileName: "obs.fm2", obsoletedById: 99),
        ]
        let playable = TASPublication.playable(pubs)
        XCTAssertEqual(playable.map(\.id), [4, 1]) // sorted by title, fm2 only
    }

    func testSearchMatchesTitleAndAuthorsCaseInsensitively() {
        let pub = makePub(title: "NES Mega Man \"zipless\" in 12:23",
                          authors: ["Deign"])
        XCTAssertTrue(TASPublication.matches(pub, search: "mega man"))
        XCTAssertTrue(TASPublication.matches(pub, search: "deign"))
        XCTAssertTrue(TASPublication.matches(pub, search: "  MEGA  ".trimmingCharacters(in: .whitespaces)))
        XCTAssertFalse(TASPublication.matches(pub, search: "zelda"))
        XCTAssertTrue(TASPublication.matches(pub, search: ""))
        XCTAssertTrue(TASPublication.matches(pub, search: "   "))
    }

    // MARK: - Display helpers

    func testDurationText() {
        XCTAssertEqual(makePub(frames: 18545, systemFrameRate: 60.0988).durationText, "05:09")
        XCTAssertEqual(makePub(frames: 78690, systemFrameRate: 60).durationText, "21:52")
        XCTAssertEqual(makePub(frames: 300_000, systemFrameRate: 60).durationText, "1:23:20")
        XCTAssertEqual(makePub(frames: 100, systemFrameRate: 0).durationText, "—")
        XCTAssertEqual(makePub(frames: 0, systemFrameRate: 60).durationText, "—")
    }

    func testYoutubeURLPrefersFirstYoutubeLink() {
        let pub = makePub(urls: [
            "https://archive.org/download/foo/foo.mp4",
            "https://youtu.be/abc",
            "https://www.youtube.com/watch?v=def",
        ])
        XCTAssertEqual(pub.youtubeURL?.absoluteString, "https://youtu.be/abc")
        XCTAssertNil(makePub(urls: ["https://archive.org/x.mp4"]).youtubeURL)
    }

    func testAuthorsText() {
        XCTAssertEqual(makePub(authors: ["a", "b"]).authorsText, "a, b")
        XCTAssertEqual(makePub(authors: []).authorsText, "")
    }
}
