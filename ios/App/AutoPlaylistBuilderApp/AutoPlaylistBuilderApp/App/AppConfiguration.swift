import Foundation
import SpotifyAPIKit

enum AppConfiguration {
    static let keychainService = "autoplaylistbuilder.production.tokens"
    static let keychainAccount = "default-user"

    static var spotifyConfiguration: SpotifyAPIConfiguration {
        let secrets = loadSecrets()
        guard let redirectURL = URL(string: secrets.redirectURI) else {
            fatalError("Invalid redirect URI in AppSecrets.plist")
        }
        return SpotifyAPIConfiguration(
            clientID: secrets.clientID,
            redirectURI: redirectURL,
            scopes: secrets.scopes
        )
    }

    /// Optional shared/demo suggestions provider.
    ///
    /// If `suggestions_refresh_token` is present in AppSecrets.plist, suggestions (`/v1/search`) will run
    /// under that refresh token instead of the signed-in user's token.
    static var artistSuggestionProvider: ArtistSuggestionProviding? {
        let secrets = loadSecrets()

        // Preferred: use a backend (e.g. Cloud Run) so no Spotify secrets/tokens ship in the app.
        if let backendURLString = secrets.suggestionsBackendURL,
           let backendURL = URL(string: backendURLString),
           !backendURLString.isEmpty {
            return CloudSuggestionsClient(
                configuration: .init(
                    baseURL: backendURL,
                    apiKey: secrets.suggestionsBackendAPIKey
                )
            )
        }

        guard let refreshToken = secrets.suggestionsRefreshToken, !refreshToken.isEmpty else {
            return nil
        }
        let configuration = spotifyConfiguration
        let authenticator = SpotifyPKCEAuthenticator(configuration: configuration)
        let tokenProvider = RefreshTokenAccessTokenProvider(refreshToken: refreshToken, refresher: authenticator)
        return SpotifyAPIClient(configuration: configuration, tokenProvider: tokenProvider)
    }

    static var artistIdeasProvider: ArtistIdeasProviding? {
        let secrets = loadSecrets()

        if let backendURLString = secrets.suggestionsBackendURL,
           let backendURL = URL(string: backendURLString),
           !backendURLString.isEmpty {
            return CloudSuggestionsClient(
                configuration: .init(
                    baseURL: backendURL,
                    apiKey: secrets.suggestionsBackendAPIKey
                )
            )
        }

        return nil
    }

    private static func loadSecrets() -> Secrets {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "AppSecrets", withExtension: "plist"),
           let data = try? Data(contentsOf: url) {
            return decodeSecrets(data: data)
        }
        guard let exampleURL = bundle.url(forResource: "AppSecrets.example", withExtension: "plist"),
              let exampleData = try? Data(contentsOf: exampleURL) else {
            fatalError("Missing AppSecrets.plist. Copy AppSecrets.example.plist and fill in your Spotify credentials.")
        }
        print("⚠️ Using AppSecrets.example.plist. Create AppSecrets.plist with real credentials before shipping.")
        return decodeSecrets(data: exampleData)
    }

    private static func decodeSecrets(data: Data) -> Secrets {
        do {
            return try PropertyListDecoder().decode(Secrets.self, from: data)
        } catch {
            fatalError("Failed to decode AppSecrets plist: \(error)")
        }
    }

    private struct Secrets: Decodable {
        let clientID: String
        let redirectURI: String
        let scopes: [String]
        let suggestionsRefreshToken: String?
        let suggestionsBackendURL: String?
        let suggestionsBackendAPIKey: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case redirectURI = "redirect_uri"
            case scopes
            case suggestionsRefreshToken = "suggestions_refresh_token"
            case suggestionsBackendURL = "suggestions_backend_url"
            case suggestionsBackendAPIKey = "suggestions_backend_api_key"
        }
    }
}
