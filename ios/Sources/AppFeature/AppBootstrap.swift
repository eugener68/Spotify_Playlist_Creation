import Foundation
import DomainKit
import SpotifyAPIKit
#if canImport(SwiftUI)
import SwiftUI
#endif

public struct AppDependencies {
    public var playlistBuilder: PlaylistBuilder
    public var apiClient: SpotifyAPIClient

    public init(
        playlistBuilder: PlaylistBuilder,
        apiClient: SpotifyAPIClient
    ) {
        self.playlistBuilder = playlistBuilder
        self.apiClient = apiClient
    }

    public static func live(
        configuration: SpotifyAPIConfiguration,
        tokenProvider: SpotifyAccessTokenProviding
    ) -> AppDependencies {
        let apiClient = SpotifyAPIClient(
            configuration: configuration,
            tokenProvider: tokenProvider
        )
        let builderDependencies = PlaylistBuilderDependencies(
            profileProvider: apiClient,
            artistProvider: apiClient,
            trackProvider: apiClient,
            playlistEditor: apiClient
        )
        let builder = PlaylistBuilder(dependencies: builderDependencies)
        return AppDependencies(playlistBuilder: builder, apiClient: apiClient)
    }

    public static func preview() -> AppDependencies {
        let configuration = SpotifyAPIConfiguration(
            clientID: "preview-client",
            redirectURI: URL(string: "autoplaylistbuilder://callback")!,
            scopes: ["playlist-modify-private", "user-read-email"]
        )
        let tokenSet = SpotifyTokenSet(
            accessToken: "preview-access-token",
            refreshToken: "preview-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            scope: configuration.scopes.joined(separator: " "),
            tokenType: "Bearer"
        )
        let tokenStore = InMemoryTokenStore(initial: tokenSet)
        let authenticator = SpotifyPKCEAuthenticator(configuration: configuration)
        let provider = RefreshingAccessTokenProvider(tokenStore: tokenStore, refresher: authenticator)
        return .live(configuration: configuration, tokenProvider: provider)
    }

    public static func liveWithPKCE(
        configuration: SpotifyAPIConfiguration,
        tokenStore: SpotifyTokenStore,
        authenticator: SpotifyPKCEAuthenticator
    ) -> AppDependencies {
        let provider = RefreshingAccessTokenProvider(
            tokenStore: tokenStore,
            refresher: authenticator
        )
        return .live(configuration: configuration, tokenProvider: provider)
    }
}

#if canImport(SwiftUI)
public struct RootView: View {
    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    private let dependencies: AppDependencies

    public var body: some View {
        Text("AutoPlaylistBuilder")
            .font(.title2)
            .bold()
            .padding()
            .accessibilityIdentifier("root_title")
    }
}
#endif
