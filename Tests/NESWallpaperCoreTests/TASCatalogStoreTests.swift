// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import NESWallpaperCore

final class TASCatalogStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nes-wallpaper-tests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private var fileURL: URL {
        tempDir.appendingPathComponent("tasvideos-catalog.json")
    }

    private func makeCatalog(fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000))
        -> TASCatalog {
        let pub = TASPublication(id: 1, title: "NES Game", movieFileName: "g.fm2",
                                 frames: 100, systemFrameRate: 60, authors: ["a"],
                                 obsoletedById: nil, publicationClass: "Standard",
                                 urls: ["https://youtu.be/x"])
        return TASCatalog(fetchedAt: fetchedAt, publications: [pub])
    }

    func testSaveLoadRoundtrip() throws {
        let store = TASCatalogStore(directory: tempDir)
        let catalog = makeCatalog()
        try store.save(catalog)
        XCTAssertEqual(store.load(), catalog)
    }

    func testSaveCreatesDirectory() throws {
        let nested = tempDir.appendingPathComponent("a/b")
        let store = TASCatalogStore(directory: nested)
        try store.save(makeCatalog())
        XCTAssertNotNil(store.load())
    }

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(TASCatalogStore(directory: tempDir).load())
    }

    func testLoadCorruptFileReturnsNilAndDeletes() throws {
        try Data("{broken".utf8).write(to: fileURL)
        let store = TASCatalogStore(directory: tempDir)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testIsStale() {
        let store = TASCatalogStore(directory: tempDir)
        let fetched = Date(timeIntervalSince1970: 0)
        let catalog = makeCatalog(fetchedAt: fetched)
        XCTAssertFalse(store.isStale(catalog, ttl: 100, now: fetched.addingTimeInterval(100)))
        XCTAssertTrue(store.isStale(catalog, ttl: 100, now: fetched.addingTimeInterval(101)))
    }
}
