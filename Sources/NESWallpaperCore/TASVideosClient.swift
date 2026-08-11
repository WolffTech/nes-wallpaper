import Foundation

/// Minimal async HTTP abstraction so the client and installer can be tested
/// without network access. `URLSession` conforms for free.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public enum TASVideosError: Error, LocalizedError {
    case notHTTP
    case badStatus(Int)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: return "Unexpected non-HTTP response from tasvideos.org."
        case .badStatus(let code): return "tasvideos.org returned HTTP \(code)."
        case .decoding: return "Could not read the tasvideos.org response."
        }
    }
}

/// Read-only client for the tasvideos.org v1 API (no authentication).
public struct TASVideosClient: Sendable {
    static let baseURL = URL(string: "https://tasvideos.org")!
    static let pageSize = 100 // the API's maximum; larger values are a 400
    /// Well above the ~10 pages of current NES publications; guarantees
    /// termination even if the API stops honoring paging.
    static let maxPages = 50
    static let userAgent = "nes-wallpaper/1.0 (macOS)"

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    /// Fetches every current NES publication, paging sequentially until a
    /// short page. All formats are returned; filter with
    /// `TASPublication.playable(_:)`.
    public func fetchAllNESPublications() async throws -> [TASPublication] {
        var all: [TASPublication] = []
        for page in 1...Self.maxPages {
            var components = URLComponents(
                url: Self.baseURL.appendingPathComponent("api/v1/publications"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "Systems", value: "nes"),
                URLQueryItem(name: "ShowObsoleted", value: "false"),
                URLQueryItem(name: "PageSize", value: "\(Self.pageSize)"),
                URLQueryItem(name: "CurrentPage", value: "\(page)"),
            ]
            let data = try await get(components.url!)
            let publications: [TASPublication]
            do {
                publications = try JSONDecoder().decode([TASPublication].self, from: data)
            } catch {
                throw TASVideosError.decoding(error)
            }
            all.append(contentsOf: publications)
            if publications.count < Self.pageSize { break }
        }
        return all
    }

    /// Downloads a publication's movie file archive (a zip containing the
    /// movie) from `https://tasvideos.org/{id}M?handler=Download`.
    public func downloadMovieArchive(publicationID: Int) async throws -> Data {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("\(publicationID)M"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handler", value: "Download")]
        return try await get(components.url!)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TASVideosError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TASVideosError.badStatus(http.statusCode)
        }
        return data
    }
}
