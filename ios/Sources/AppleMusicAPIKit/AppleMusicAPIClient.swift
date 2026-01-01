import DomainKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppleMusicAPIClient: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case missingStorefront
        case invalidURL
        case unexpectedStatus(Int, String)
        case noSongMatch(String)

        public var errorDescription: String? {
            switch self {
            case .missingStorefront:
                return "Apple Music storefront is unavailable."
            case .invalidURL:
                return "Apple Music request URL is invalid."
            case let .unexpectedStatus(code, body):
                return body.isEmpty ? "Apple Music API failed (HTTP \(code))." : "Apple Music API failed (HTTP \(code)): \(body)"
            case let .noSongMatch(query):
                return "Could not find an Apple Music match for: \(query)"
            }
        }
    }

    private let authenticator: AppleMusicAuthenticator
    private let urlSession: URLSession

    public init(authenticator: AppleMusicAuthenticator, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.authenticator = authenticator
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    public func createPlaylist(from draft: PlaylistDraft) async throws -> (playlistID: String, addedSongIDs: [String]) {
        // Ensure we have the tokens up-front.
        let developerToken = try await authenticator.developerToken()
        let userToken = try await authenticator.musicUserToken()
        let storefront = try await authenticator.storefrontID()
        guard !storefront.isEmpty else { throw Error.missingStorefront }

        // Resolve Apple Music song ids.
        var songIDs: [String] = []
        songIDs.reserveCapacity(draft.tracks.count)

        for track in draft.tracks {
            if let existing = track.appleMusicSongID, !existing.isEmpty {
                songIDs.append(existing)
                continue
            }

            let query = Self.searchQuery(for: track)
            let songID = try await searchSongID(
                query: query,
                storefront: storefront,
                developerToken: developerToken
            )
            songIDs.append(songID)
        }

        let playlistID = try await createLibraryPlaylist(
            name: draft.name,
            description: draft.description,
            developerToken: developerToken,
            userToken: userToken
        )

        if !songIDs.isEmpty {
            try await addSongs(
                songIDs,
                toLibraryPlaylistID: playlistID,
                developerToken: developerToken,
                userToken: userToken
            )
        }

        return (playlistID: playlistID, addedSongIDs: songIDs)
    }
}

private extension AppleMusicAPIClient {
    static func searchQuery(for track: TrackDescriptor) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistNames.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !artist.isEmpty {
            return "\(title) \(artist)"
        }
        return title
    }

    func searchSongID(query: String, storefront: String, developerToken: String) async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/catalog/\(storefront)/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { throw Error.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(-1, "Bad server response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.unexpectedStatus(http.statusCode, body)
        }

        struct Root: Decodable {
            struct Results: Decodable {
                struct Songs: Decodable {
                    struct DataItem: Decodable { let id: String }
                    let data: [DataItem]?
                }
                let songs: Songs?
            }
            let results: Results?
        }

        let decoded = try JSONDecoder().decode(Root.self, from: data)
        if let id = decoded.results?.songs?.data?.first?.id, !id.isEmpty {
            return id
        }
        throw Error.noSongMatch(query)
    }

    func createLibraryPlaylist(name: String, description: String?, developerToken: String, userToken: String) async throws -> String {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists") else {
            throw Error.invalidURL
        }

        struct Body: Encodable {
            struct Attributes: Encodable {
                let name: String
                let description: String?
            }
            let attributes: Attributes
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONEncoder().encode(Body(attributes: .init(name: name, description: description)))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(-1, "Bad server response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.unexpectedStatus(http.statusCode, body)
        }

        struct Root: Decodable {
            struct DataItem: Decodable { let id: String }
            let data: [DataItem]
        }

        let decoded = try JSONDecoder().decode(Root.self, from: data)
        guard let id = decoded.data.first?.id, !id.isEmpty else {
            throw Error.unexpectedStatus(http.statusCode, "Missing playlist id")
        }
        return id
    }

    func addSongs(_ songIDs: [String], toLibraryPlaylistID playlistID: String, developerToken: String, userToken: String) async throws {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(playlistID)/tracks") else {
            throw Error.invalidURL
        }

        struct Body: Encodable {
            struct Item: Encodable {
                let id: String
                let type: String
            }
            let data: [Item]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(data: songIDs.map { Body.Item(id: $0, type: "songs") })
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(-1, "Bad server response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.unexpectedStatus(http.statusCode, body)
        }
    }
}
