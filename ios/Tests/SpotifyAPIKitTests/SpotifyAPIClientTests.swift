import XCTest
@testable import SpotifyAPIKit

final class SpotifyAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.handler = nil
    }

    func testSearchArtistsReturnsDecodedItems() async throws {
        let expectedJSON = """
        {
          "artists": {
            "items": [
              { "id": "metallica", "name": "Metallica" },
              { "id": "aha", "name": "A-ha" }
            ]
          }
        }
        """.data(using: .utf8)!

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/search")
            XCTAssertTrue(request.url?.absoluteString.contains("type=artist") ?? false)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, expectedJSON)
        }

        let client = makeClient()
        let artists = try await client.searchArtists("Metallica", limit: 2)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first?.name, "Metallica")
    }

    func testUnauthorizedResponseThrowsError() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        await XCTAssertThrowsErrorAsync(try await client.topTracks(for: "metallica", limit: 2)) { error in
            guard case SpotifyAPIError.unauthorized = error else {
                XCTFail("Expected unauthorized error")
                return
            }
        }
    }

    // MARK: - Helpers

    private func makeClient() -> SpotifyAPIClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [URLProtocolStub.self]
        let config = SpotifyAPIConfiguration(
            clientID: "client",
            redirectURI: URL(string: "autoplaylistbuilder://callback")!,
            scopes: ["playlist-modify-private"]
        )
        return SpotifyAPIClient(
            configuration: config,
            tokenProvider: StaticTokenProvider(token: "test-token"),
            urlSessionConfiguration: sessionConfig
        )
    }
}

private struct StaticTokenProvider: SpotifyAccessTokenProviding {
    let token: String

    func accessToken() async throws -> String { token }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = URLProtocolStub.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
