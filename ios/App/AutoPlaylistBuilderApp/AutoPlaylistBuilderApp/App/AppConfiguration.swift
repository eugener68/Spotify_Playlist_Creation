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

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case redirectURI = "redirect_uri"
            case scopes
        }
    }
}
