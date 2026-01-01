import SwiftUI
import AppFeature
import SpotifyAPIKit
import AppleMusicAPIKit

@main
struct AutoPlaylistBuilderApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(
                configuration: AppConfiguration.spotifyConfiguration,
                keychainService: AppConfiguration.keychainService,
                keychainAccount: AppConfiguration.keychainAccount,
                artistSuggestionProvider: AppConfiguration.artistSuggestionProvider,
                appleMusicAuthenticator: AppConfiguration.appleMusicAuthenticator,
                artistIdeasProvider: AppConfiguration.artistIdeasProvider
            )
        }
    }
}
