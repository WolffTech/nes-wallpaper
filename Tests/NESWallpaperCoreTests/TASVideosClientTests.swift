// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import NESWallpaperCore

/// Serves queued responses in order and records every request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<(Data, URLResponse), Error>] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(data: Data, status: Int = 200, url: URL = TASVideosClient.baseURL) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        lock.lock()
        queue.append(.success((data, response)))
        lock.unlock()
    }

    func enqueue(error: Error) {
        lock.lock()
        queue.append(.failure(error))
        lock.unlock()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        let next = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        guard let next else {
            XCTFail("unexpected request: \(request.url?.absoluteString ?? "?")")
            throw URLError(.badServerResponse)
        }
        return try next.get()
    }
}

final class TASVideosClientTests: XCTestCase {
    private func pageJSON(ids: Range<Int>) throws -> Data {
        let pubs = ids.map {
            TASPublication(id: $0, title: "NES Game \($0)", movieFileName: "game\($0).fm2",
                           frames: 1000, systemFrameRate: 60, authors: ["a"],
                           obsoletedById: nil, publicationClass: "Standard", urls: [])
        }
        return try JSONEncoder().encode(pubs)
    }

    func testFetchPagesUntilShortPage() async throws {
        let transport = StubTransport()
        transport.enqueue(data: try pageJSON(ids: 0..<100))
        transport.enqueue(data: try pageJSON(ids: 100..<200))
        transport.enqueue(data: try pageJSON(ids: 200..<210))

        let pubs = try await TASVideosClient(transport: transport).fetchAllNESPublications()
        XCTAssertEqual(pubs.count, 210)
        XCTAssertEqual(pubs.first?.id, 0)
        XCTAssertEqual(pubs.last?.id, 209)

        XCTAssertEqual(transport.requests.count, 3)
        for (index, request) in transport.requests.enumerated() {
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertTrue(url.hasPrefix("https://tasvideos.org/api/v1/publications?"))
            XCTAssertTrue(url.contains("Systems=nes"))
            XCTAssertTrue(url.contains("ShowObsoleted=false"))
            XCTAssertTrue(url.contains("PageSize=100"))
            XCTAssertTrue(url.contains("CurrentPage=\(index + 1)"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"),
                           TASVideosClient.userAgent)
        }
    }

    func testFetchStopsOnEmptyFirstPage() async throws {
        let transport = StubTransport()
        transport.enqueue(data: Data("[]".utf8))
        let pubs = try await TASVideosClient(transport: transport).fetchAllNESPublications()
        XCTAssertTrue(pubs.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFetchThrowsOnBadStatus() async throws {
        let transport = StubTransport()
        transport.enqueue(data: Data(), status: 503)
        do {
            _ = try await TASVideosClient(transport: transport).fetchAllNESPublications()
            XCTFail("expected badStatus")
        } catch TASVideosError.badStatus(let code) {
            XCTAssertEqual(code, 503)
        }
    }

    func testFetchThrowsDecodingOnGarbage() async throws {
        let transport = StubTransport()
        transport.enqueue(data: Data("not json".utf8))
        do {
            _ = try await TASVideosClient(transport: transport).fetchAllNESPublications()
            XCTFail("expected decoding error")
        } catch TASVideosError.decoding {
            // expected
        }
    }

    func testDownloadMovieArchiveURLAndBytes() async throws {
        let transport = StubTransport()
        let zipBytes = Data([0x50, 0x4B, 0x03, 0x04, 0xFF])
        transport.enqueue(data: zipBytes)

        let data = try await TASVideosClient(transport: transport)
            .downloadMovieArchive(publicationID: 1234)
        XCTAssertEqual(data, zipBytes)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString,
                       "https://tasvideos.org/1234M?handler=Download")
    }
}
