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
        playlistBuilder: PlaylistBuilder = PlaylistBuilder(),
        apiClient: SpotifyAPIClient = SpotifyAPIClient()
    ) {
        self.playlistBuilder = playlistBuilder
        self.apiClient = apiClient
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
