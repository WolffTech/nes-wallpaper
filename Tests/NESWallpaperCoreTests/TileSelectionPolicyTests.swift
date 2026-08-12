import XCTest
@testable import NESWallpaperCore

final class TileSelectionPolicyTests: XCTestCase {
    private func spec(_ rom: String) -> TileSpec {
        TileSpec(rom: rom, movie: nil)
    }

    func testStartupUsesUnusedGamesUntilCatalogIsExhausted() throws {
        let catalog = ["a", "b", "c"]
        let source: TileSelectionPolicy.Source = { excluded in
            catalog.first { !excluded.contains($0) }.map(self.spec)
        }

        var assigned: [TileSpec] = []
        for _ in catalog {
            assigned.append(try XCTUnwrap(TileSelectionPolicy.startup(
                source: source, assigned: assigned)))
        }

        XCTAssertEqual(Set(assigned.map(\.rom)), Set(catalog))
    }

    func testStartupFallsBackWhenGridIsLargerThanCatalog() throws {
        let source: TileSelectionPolicy.Source = { excluded in
            excluded.contains("only") ? nil : self.spec("only")
        }

        let replacement = try XCTUnwrap(TileSelectionPolicy.startup(
            source: source, assigned: [spec("only")]))
        XCTAssertEqual(replacement.rom, "only")
    }

    func testRotationPrefersGameThatIsEntirelyOffScreen() throws {
        let catalog = ["a", "b", "c"]
        let source: TileSelectionPolicy.Source = { excluded in
            catalog.first { !excluded.contains($0) }.map(self.spec)
        }

        let replacement = try XCTUnwrap(TileSelectionPolicy.replacement(
            source: source, displayed: [spec("a"), spec("b")], replacing: 0))
        XCTAssertEqual(replacement.rom, "c")
    }

    func testRotationKeepsTargetGameWhenExactlyEnoughGamesExist() throws {
        let catalog = ["a", "b"]
        let source: TileSelectionPolicy.Source = { excluded in
            catalog.first { !excluded.contains($0) }.map(self.spec)
        }

        let replacement = try XCTUnwrap(TileSelectionPolicy.replacement(
            source: source, displayed: [spec("a"), spec("b")], replacing: 0))
        XCTAssertEqual(replacement.rom, "a")
    }

    func testRotationFallsBackWhenDuplicatesAreUnavoidable() throws {
        let source: TileSelectionPolicy.Source = { excluded in
            excluded.contains("only") ? nil : self.spec("only")
        }

        let replacement = try XCTUnwrap(TileSelectionPolicy.replacement(
            source: source, displayed: [spec("only"), spec("only")], replacing: 0))
        XCTAssertEqual(replacement.rom, "only")
    }
}
