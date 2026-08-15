// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A fetched snapshot of the playable TASVideos catalog.
public struct TASCatalog: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let publications: [TASPublication]

    public init(fetchedAt: Date, publications: [TASPublication]) {
        self.fetchedAt = fetchedAt
        self.publications = publications
    }
}

/// Persists the catalog as a single JSON file so the browser opens instantly
/// after the first fetch.
public final class TASCatalogStore {
    public static let defaultTTL: TimeInterval = 7 * 24 * 3600

    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("tasvideos-catalog.json")
    }

    /// `~/Library/Application Support/nes-wallpaper`.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nes-wallpaper", isDirectory: true)
    }

    /// nil when the file is missing; a corrupt file is deleted and nil returned.
    public func load() -> TASCatalog? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let catalog = try? decoder.decode(TASCatalog.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return catalog
    }

    public func save(_ catalog: TASCatalog) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(to: fileURL, options: [.atomic])
    }

    public func isStale(_ catalog: TASCatalog,
                        ttl: TimeInterval = TASCatalogStore.defaultTTL,
                        now: Date = Date()) -> Bool {
        now.timeIntervalSince(catalog.fetchedAt) > ttl
    }
}
