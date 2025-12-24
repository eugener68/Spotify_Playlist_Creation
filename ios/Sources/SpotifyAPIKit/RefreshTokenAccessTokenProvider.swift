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
        do {
            let response = try await refresher.refreshAccessToken(refreshToken: refreshToken)
            let newSet = SpotifyTokenSet(response: response, fallbackRefreshToken: refreshToken)
            cachedToken = newSet
            return newSet.accessToken
        } catch let error as SpotifyAPIError {
            cachedToken = nil
            let base = "Shared suggestions token is invalid, revoked, or mismatched with this client_id. Regenerate suggestions_refresh_token and rebuild the app."
            if case let .api(status, message) = error {
                throw SpotifyAPIError.api(status: status, message: "\(base) (\(message))")
            }
            throw SpotifyAPIError.api(status: 401, message: base)
        }
    }

    public func clearCache() {
        cachedToken = nil
    }
}
