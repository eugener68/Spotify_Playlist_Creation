import XCTest
@testable import SpotifyAPIKit

final class RefreshingAccessTokenProviderTests: XCTestCase {
    func testReturnsCachedTokenWhenFresh() async throws {
        let refresher = MockTokenRefresher()
        let store = InMemoryTokenStore(initial: freshToken())
        let provider = RefreshingAccessTokenProvider(tokenStore: store, refresher: refresher, refreshTolerance: 5)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "fresh-token")
        XCTAssertFalse(refresher.didRefresh)
    }

    func testRefreshesWhenExpired() async throws {
        let refresher = MockTokenRefresher(returning: SpotifyTokenResponse(
            accessToken: "new-token",
            tokenType: "Bearer",
            scope: nil,
            expiresIn: 3600,
            refreshToken: nil
        ))
        let expired = SpotifyTokenSet(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(-10),
            scope: nil,
            tokenType: "Bearer"
        )
        let store = InMemoryTokenStore(initial: expired)
        let provider = RefreshingAccessTokenProvider(tokenStore: store, refresher: refresher, refreshTolerance: 5)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "new-token")
        XCTAssertTrue(refresher.didRefresh)
    }

    func testThrowsWhenNoRefreshToken() async {
        let refresher = MockTokenRefresher()
        let expired = SpotifyTokenSet(
            accessToken: "old",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-10),
            scope: nil,
            tokenType: "Bearer"
        )
        let store = InMemoryTokenStore(initial: expired)
        let provider = RefreshingAccessTokenProvider(tokenStore: store, refresher: refresher, refreshTolerance: 5)
        await XCTAssertThrowsErrorAsync(try await provider.accessToken())
    }

    // MARK: - Helpers

    private func freshToken() -> SpotifyTokenSet {
        SpotifyTokenSet(
            accessToken: "fresh-token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scope: nil,
            tokenType: "Bearer"
        )
    }
}

private final class MockTokenRefresher: SpotifyTokenRefreshing, @unchecked Sendable {
    var didRefresh = false
    var response: SpotifyTokenResponse

    init(returning response: SpotifyTokenResponse? = nil) {
        self.response = response ?? SpotifyTokenResponse(
            accessToken: "refreshed",
            tokenType: "Bearer",
            scope: nil,
            expiresIn: 3600,
            refreshToken: "refresh"
        )
    }

    func refreshAccessToken(refreshToken: String) async throws -> SpotifyTokenResponse {
        didRefresh = true
        return response
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected
    }
}
