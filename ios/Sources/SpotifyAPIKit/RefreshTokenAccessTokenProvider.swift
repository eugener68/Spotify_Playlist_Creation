import Foundation

/// Provides a Spotify access token by continuously refreshing a single, pre-provisioned refresh token.
///
/// This is useful for non-user-critical calls (e.g. artist suggestions) when you want to run those calls
/// under a shared/demo Spotify account.
///
/// IMPORTANT: Do not ship a real refresh token inside a public client app. Prefer fetching an app token
/// from a backend (Client Credentials) or moving the Spotify app out of allowlisted development mode.
public actor RefreshTokenAccessTokenProvider: SpotifyAccessTokenProviding {
    private let refreshToken: String
    private let refresher: SpotifyTokenRefreshing
    private var cachedToken: SpotifyTokenSet?
    private let refreshTolerance: TimeInterval

    public init(
        refreshToken: String,
        refresher: SpotifyTokenRefreshing,
        refreshTolerance: TimeInterval = 60
    ) {
        self.refreshToken = refreshToken
        self.refresher = refresher
        self.refreshTolerance = refreshTolerance
    }

    public func accessToken() async throws -> String {
        if let cached = cachedToken, !cached.willExpire(within: refreshTolerance) {
            return cached.accessToken
        }
        let response = try await refresher.refreshAccessToken(refreshToken: refreshToken)
        let newSet = SpotifyTokenSet(response: response, fallbackRefreshToken: refreshToken)
        cachedToken = newSet
        return newSet.accessToken
    }

    public func clearCache() {
        cachedToken = nil
    }
}
