import SwiftUI
import AppFeature
import SpotifyAPIKit
import AppleMusicAPIKit

@main
struct AutoPlaylistBuilderApp: App {
    private let configuration = AppConfiguration.spotifyConfiguration

    var body: some Scene {
        WindowGroup {
            RootView(
                configuration: configuration,
                keychainService: AppConfiguration.keychainService,
                keychainAccount: AppConfiguration.keychainAccount,
                artistSuggestionProvider: AppConfiguration.artistSuggestionProvider,
                appleMusicAuthenticator: AppConfiguration.appleMusicAuthenticator
            )
        }
    }
}
