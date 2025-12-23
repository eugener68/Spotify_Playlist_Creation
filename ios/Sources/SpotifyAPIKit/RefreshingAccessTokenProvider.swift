import Foundation

public actor RefreshingAccessTokenProvider: SpotifyAccessTokenProviding {
    private let tokenStore: SpotifyTokenStore
    private let refresher: SpotifyTokenRefreshing
    private var cachedToken: SpotifyTokenSet?
    private let refreshTolerance: TimeInterval
    private let requiredScopes: Set<String>

    public init(
        tokenStore: SpotifyTokenStore,
        refresher: SpotifyTokenRefreshing,
        requiredScopes: Set<String> = [],
        refreshTolerance: TimeInterval = 60
    ) {
        self.tokenStore = tokenStore
        self.refresher = refresher
        self.requiredScopes = requiredScopes
        self.refreshTolerance = refreshTolerance
    }

    public func accessToken() async throws -> String {
        if let cached = cachedToken, !cached.willExpire(within: refreshTolerance) {
            try validateScopes(token: cached)
            return cached.accessToken
        }
        let stored = try await tokenStore.load()
        do {
            let token = try await refreshIfNeeded(token: stored)
            try validateScopes(token: token)
            cachedToken = token
            return token.accessToken
        } catch SpotifyAPIError.unauthorized {
            try await tokenStore.clear()
            cachedToken = nil
            throw SpotifyAPIError.unauthorized
        }
    }

    @discardableResult
    public func update(token: SpotifyTokenSet) async throws -> SpotifyTokenSet {
        try await tokenStore.save(token)
        cachedToken = token
        return token
    }

    public func clear() async throws {
        try await tokenStore.clear()
        cachedToken = nil
    }

    private func refreshIfNeeded(token: SpotifyTokenSet?) async throws -> SpotifyTokenSet {
        guard let token else {
            throw SpotifyAPIError.unauthorized
        }
        if !token.willExpire(within: refreshTolerance) {
            return token
        }
        guard let refreshToken = token.refreshToken else {
            throw SpotifyAPIError.unauthorized
        }
        let response = try await refresher.refreshAccessToken(refreshToken: refreshToken)
        let newSet = SpotifyTokenSet(
            response: response,
            fallbackRefreshToken: refreshToken,
            fallbackScope: token.scope
        )
        try await tokenStore.save(newSet)
        return newSet
    }

    private func validateScopes(token: SpotifyTokenSet) throws {
        guard !requiredScopes.isEmpty else {
            return
        }
        guard let scopeString = token.scope else {
            throw SpotifyAPIError.unauthorized
        }
        let granted = Set(scopeString.split(separator: " ").map { String($0) }.filter { !$0.isEmpty })
        if !requiredScopes.isSubset(of: granted) {
            throw SpotifyAPIError.unauthorized
        }
    }
}
