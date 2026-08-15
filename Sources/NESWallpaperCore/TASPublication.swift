// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A TASVideos publication as returned by
/// `GET https://tasvideos.org/api/v1/publications`. Only the fields the app
/// displays or filters on are decoded; Codable ignores the rest.
public struct TASPublication: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    /// Full display string, e.g.
    /// `NES Super Mario Bros. "warpless" by HappyLee in 18:36.78`.
    public let title: String
    /// Movie file name with extension, e.g. `happylee-smb-warpless.fm2`.
    /// Unique across current publications, so it doubles as the install key.
    public let movieFileName: String
    public let frames: Int
    public let systemFrameRate: Double
    public let authors: [String]
    /// The id of the publication that obsoletes this one, if any.
    public let obsoletedById: Int?
    /// Publication class, e.g. "Standard", "Moons", "Stars".
    public let publicationClass: String?
    /// Related links (encode video mirrors, YouTube, etc.) as plain strings.
    public let urls: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, movieFileName, frames, systemFrameRate, authors
        case obsoletedById
        case publicationClass = "class"
        case urls
    }

    public init(id: Int, title: String, movieFileName: String, frames: Int,
                systemFrameRate: Double, authors: [String], obsoletedById: Int?,
                publicationClass: String?, urls: [String]) {
        self.id = id
        self.title = title
        self.movieFileName = movieFileName
        self.frames = frames
        self.systemFrameRate = systemFrameRate
        self.authors = authors
        self.obsoletedById = obsoletedById
        self.publicationClass = publicationClass
        self.urls = urls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        movieFileName = try container.decode(String.self, forKey: .movieFileName)
        frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        systemFrameRate = try container.decodeIfPresent(
            Double.self, forKey: .systemFrameRate) ?? 0
        authors = (try? container.decodeIfPresent([String].self, forKey: .authors)) ?? []
        obsoletedById = try container.decodeIfPresent(Int.self, forKey: .obsoletedById)
        publicationClass = try? container.decodeIfPresent(
            String.self, forKey: .publicationClass)
        urls = (try? container.decodeIfPresent([String].self, forKey: .urls)) ?? []
    }

    /// Whether the movie is an FCEUX FM2 — the only format the app can play.
    public var isFM2: Bool {
        movieFileName.lowercased().hasSuffix(".fm2")
    }

    public var isObsoleted: Bool {
        obsoletedById != nil
    }

    /// Run length as `MM:SS` (or `H:MM:SS`), or `—` without a frame rate.
    public var durationText: String {
        guard systemFrameRate > 0, frames > 0 else { return "—" }
        let total = Int((Double(frames) / systemFrameRate).rounded())
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    public var youtubeURL: URL? {
        urls.lazy
            .filter { $0.contains("youtube.com") || $0.contains("youtu.be") }
            .compactMap(URL.init(string:))
            .first
    }

    public var authorsText: String {
        authors.joined(separator: ", ")
    }

    /// The publications the app can actually play: current (non-obsoleted)
    /// FM2 movies, sorted by title.
    public static func playable(_ publications: [TASPublication]) -> [TASPublication] {
        publications
            .filter { $0.isFM2 && !$0.isObsoleted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Case-insensitive search over title and authors; an empty or
    /// whitespace-only search matches everything.
    public static func matches(_ publication: TASPublication, search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if publication.title.localizedCaseInsensitiveContains(trimmed) { return true }
        return publication.authors.contains {
            $0.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
