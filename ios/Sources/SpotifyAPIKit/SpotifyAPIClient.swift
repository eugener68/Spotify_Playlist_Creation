import Foundation
import DomainKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SpotifyAPIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case decoding(Error)
    case transport(Error)
    case api(status: Int, message: String)
    case unexpectedStatus(Int)
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Spotify credentials are missing or expired."
        case let .rateLimited(retryAfter):
            return "Spotify rate limit reached. Retry after \(retryAfter) seconds."
        case let .decoding(error):
            return "Failed to decode Spotify response: \(error.localizedDescription)"
        case let .transport(error):
            return "Network error: \(error.localizedDescription)"
        case let .api(status, message):
            return "Spotify API error \(status): \(message)"
        case let .unexpectedStatus(code):
            return "Unexpected Spotify status code: \(code)"
        case .invalidURL:
            return "Failed to construct Spotify URL."
        }
    }
}

public struct SpotifyAPIConfiguration: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(clientID: String, redirectURI: URL, scopes: [String]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

public protocol SpotifyAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
}

public protocol ArtistSuggestionProviding: Sendable {
    func searchArtistSummaries(_ query: String, limit: Int) async throws -> [ArtistSummary]
}

public protocol ArtistIdeasProviding: Sendable {
    func generateArtistIdeas(prompt: String, artistCount: Int, userId: String?) async throws -> [ArtistSummary]
}

public struct ArtistSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let followers: Int?
    public let genres: [String]
    public let imageURL: URL?

    public init(id: String, name: String, followers: Int?, genres: [String], imageURL: URL?) {
        self.id = id
        self.name = name
        self.followers = followers
        self.genres = genres
        self.imageURL = imageURL
    }
}

public actor InMemoryAccessTokenProvider: SpotifyAccessTokenProviding {
    public enum TokenError: Error {
        case missing
    }

    private var token: String?

    public init(initialToken: String? = nil) {
        self.token = initialToken
    }

    public func update(_ token: String) {
        self.token = token
    }

    public func accessToken() async throws -> String {
        guard let token, !token.isEmpty else {
            throw SpotifyAPIError.unauthorized
        }
        return token
    }
}

public final class SpotifyAPIClient: @unchecked Sendable {
    private let configuration: SpotifyAPIConfiguration
    private let tokenProvider: SpotifyAccessTokenProviding
    private let urlSession: URLSession
    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    /// Set to true to print request/response details for troubleshooting.
    /// Kept internal to avoid changing the public API surface.
    static var debugLoggingEnabled: Bool = false

    public init(
        configuration: SpotifyAPIConfiguration,
        tokenProvider: SpotifyAccessTokenProviding,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.jsonDecoder = decoder
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.jsonEncoder = encoder
    }
}

// MARK: - Domain Protocol Conformance

extension SpotifyAPIClient: SpotifyProfileProviding {
    public func currentUser() async throws -> SpotifyUserProfile {
        let request = try await authorizedRequest(path: "/me")
        return try await send(request)
    }
}

extension SpotifyAPIClient: SpotifyArtistProviding {
    public func searchArtists(_ query: String, limit: Int) async throws -> [SpotifyArtist] {
        let queryItems = [
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let request = try await authorizedRequest(path: "/search", queryItems: queryItems)
        let response: SearchArtistsResponse = try await send(request)
        return response.artists.items
    }

    public func artist(byID id: String) async throws -> SpotifyArtist {
        let request = try await authorizedRequest(path: "/artists/\(id)")
        return try await send(request)
    }

    public func topArtists(limit: Int) async throws -> [SpotifyArtist] {
        let queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let request = try await authorizedRequest(path: "/me/top/artists", queryItems: queryItems)
        let response: PagedArtistsResponse = try await send(request)
        return response.items
    }

    public func followedArtists(limit: Int) async throws -> [SpotifyArtist] {
        let queryItems = [
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let request = try await authorizedRequest(path: "/me/following", queryItems: queryItems)
        let response: FollowedArtistResponse = try await send(request)
        return response.artists.items
    }
}

extension SpotifyAPIClient: SpotifyTrackProviding {
    public func topTracks(for artistID: String, limit: Int) async throws -> [SpotifyTrack] {
        let queryItems = [
            URLQueryItem(name: "market", value: "from_token"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let request = try await authorizedRequest(path: "/artists/\(artistID)/top-tracks", queryItems: queryItems)
        let response: TopTracksResponse = try await send(request)
        return Array(response.tracks.prefix(limit))
    }
}

extension SpotifyAPIClient: SpotifyPlaylistEditing {
    public func createPlaylist(
        userID: String,
        name: String,
        description: String,
        isPublic: Bool
    ) async throws -> String {
        struct CreatePlaylistRequest: Encodable {
            let name: String
            let description: String
            let `public`: Bool
        }

        struct CreatePlaylistResponse: Decodable { let id: String }

        let body = CreatePlaylistRequest(name: name, description: description, public: isPublic)
        let request = try await authorizedRequest(
            path: "/users/\(userID)/playlists",
            method: .post,
            body: try jsonEncoder.encode(body)
        )
        let response: CreatePlaylistResponse = try await send(request)
        return response.id
    }

    public func findPlaylist(named name: String, ownerID: String) async throws -> SpotifyPlaylistSummary? {
        var request = try await authorizedRequest(
            path: "/me/playlists",
            queryItems: [URLQueryItem(name: "limit", value: "50")]
        )

        while true {
            let response: UserPlaylistsResponse = try await send(request)
            if let match = response.items.first(where: { playlist in
                playlist.name.caseInsensitiveCompare(name) == .orderedSame && (playlist.owner.id ?? "") == ownerID
            }) {
                return SpotifyPlaylistSummary(
                    id: match.id,
                    name: match.name,
                    ownerID: match.owner.id ?? "",
                    trackCount: match.tracks.total
                )
            }

            guard let next = response.next, let nextURL = URL(string: next) else {
                break
            }
            request = try await authorizedRequest(absoluteURL: nextURL)
        }
        return nil
    }

    public func playlistTracks(playlistID: String) async throws -> [String] {
        var collected: [String] = []
        var request = try await authorizedRequest(
            path: "/playlists/\(playlistID)/tracks",
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        )

        while true {
            let response: PlaylistTracksResponse = try await send(request)
            collected.append(contentsOf: response.items.compactMap { $0.track?.uri })
            guard let next = response.next, let nextURL = URL(string: next) else {
                break
            }
            request = try await authorizedRequest(absoluteURL: nextURL)
        }
        return collected
    }

    public func replacePlaylistTracks(playlistID: String, uris: [String]) async throws {
        struct PlaylistTracksRequest: Encodable { let uris: [String] }

        guard !uris.isEmpty else {
            let request = try await authorizedRequest(path: "/playlists/\(playlistID)/tracks", method: .put)
            _ = try await send(request)
            return
        }

        let chunks = uris.chunked(into: 100)
        if let first = chunks.first {
            let request = try await authorizedRequest(
                path: "/playlists/\(playlistID)/tracks",
                method: .put,
                body: try jsonEncoder.encode(PlaylistTracksRequest(uris: first))
            )
            _ = try await send(request)
        }

        if chunks.count > 1 {
            for chunk in chunks.dropFirst() {
                let request = try await authorizedRequest(
                    path: "/playlists/\(playlistID)/tracks",
                    method: .post,
                    body: try jsonEncoder.encode(PlaylistTracksRequest(uris: chunk))
                )
                _ = try await send(request)
            }
        }
    }
}

extension SpotifyAPIClient: ArtistSuggestionProviding {
    public func searchArtistSummaries(_ query: String, limit: Int) async throws -> [ArtistSummary] {
        let queryItems = [
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let request = try await authorizedRequest(path: "/search", queryItems: queryItems)
        if Self.debugLoggingEnabled {
            print("🔎 Spotify suggestions request: \(request.url?.absoluteString ?? "<nil>")")
        }
        let response: SearchArtistSummaryResponse = try await send(request)
        return response.artists.items.map { item in
            ArtistSummary(
                id: item.id,
                name: item.name,
                followers: item.followers?.total,
                genres: item.genres ?? [],
                imageURL: item.images?.first?.url
            )
        }
    }
}

// MARK: - Request Helpers

private extension SpotifyAPIClient {
    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    func authorizedRequest(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: endpointURL(path), resolvingAgainstBaseURL: false) else {
            throw SpotifyAPIError.invalidURL
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw SpotifyAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let token = try await tokenProvider.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func authorizedRequest(
        absoluteURL url: URL,
        method: HTTPMethod = .get,
        body: Data? = nil
    ) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token = try await tokenProvider.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw SpotifyAPIError.decoding(error)
        }
    }

    func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.transport(URLError(.badServerResponse))
            }
            if Self.debugLoggingEnabled, request.url?.path.contains("/search") == true {
                print("🔎 Spotify suggestions status: \(httpResponse.statusCode)")
            }
            switch httpResponse.statusCode {
            case 200 ..< 300:
                return data
            case 401:
                throw SpotifyAPIError.unauthorized
            case 429:
                let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "0"
                throw SpotifyAPIError.rateLimited(retryAfter: TimeInterval(retryAfterValue) ?? 1)
            default:
                if let apiError = decodeSpotifyWebAPIError(from: data) {
                    if Self.debugLoggingEnabled, request.url?.path.contains("/search") == true {
                        print("🔎 Spotify suggestions error body: \(apiError.message)")
                    }
                    // Common case: expired or under-scoped token.
                    if apiError.status == 403, apiError.message.lowercased().contains("scope") {
                        throw SpotifyAPIError.unauthorized
                    }
                    throw SpotifyAPIError.api(status: apiError.status, message: apiError.message)
                }
                if Self.debugLoggingEnabled, request.url?.path.contains("/search") == true, let body = String(data: data, encoding: .utf8), !body.isEmpty {
                    print("🔎 Spotify suggestions error body: \(body)")
                }
                throw SpotifyAPIError.unexpectedStatus(httpResponse.statusCode)
            }
        } catch let error as SpotifyAPIError {
            if Self.debugLoggingEnabled, request.url?.path.contains("/search") == true {
                print("🔎 Spotify suggestions error: \(error.localizedDescription)")
            }
            throw error
        } catch {
            if Self.debugLoggingEnabled, request.url?.path.contains("/search") == true {
                print("🔎 Spotify suggestions transport error: \(error.localizedDescription)")
            }
            throw SpotifyAPIError.transport(error)
        }
    }

    struct SpotifyWebAPIError: Sendable {
        let status: Int
        let message: String
    }

    func decodeSpotifyWebAPIError(from data: Data) -> SpotifyWebAPIError? {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let status: Int?
                let message: String?
            }
            let error: Inner
        }

        guard let envelope = try? jsonDecoder.decode(Envelope.self, from: data) else {
            return nil
        }
        guard let status = envelope.error.status, let message = envelope.error.message, !message.isEmpty else {
            return nil
        }
        return SpotifyWebAPIError(status: status, message: message)
    }

    func endpointURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return baseURL.appendingPathComponent(String(path.dropFirst()))
        }
        return baseURL.appendingPathComponent(path)
    }
}

// MARK: - DTOs

private struct SearchArtistsResponse: Decodable {
    struct ArtistContainer: Decodable {
        let items: [SpotifyArtist]
    }

    let artists: ArtistContainer
}

private struct SearchArtistSummaryResponse: Decodable {
    struct ArtistContainer: Decodable {
        let items: [Artist]
    }

    struct Artist: Decodable {
        struct Followers: Decodable { let total: Int? }
        struct Image: Decodable { let url: URL; let width: Int?; let height: Int? }

        let id: String
        let name: String
        let followers: Followers?
        let genres: [String]?
        let images: [Image]?
    }

    let artists: ArtistContainer
}

private struct PagedArtistsResponse: Decodable {
    let items: [SpotifyArtist]
}

private struct FollowedArtistResponse: Decodable {
    struct ArtistWrapper: Decodable {
        let items: [SpotifyArtist]
    }

    let artists: ArtistWrapper
}

private struct TopTracksResponse: Decodable {
    let tracks: [SpotifyTrack]
}

private struct UserPlaylistsResponse: Decodable {
    struct Playlist: Decodable {
        struct Owner: Decodable { let id: String? }
        struct Tracks: Decodable { let total: Int }

        let id: String
        let name: String
        let owner: Owner
        let tracks: Tracks
    }

    let items: [Playlist]
    let next: String?
}

private struct PlaylistTracksResponse: Decodable {
    struct PlaylistTrackItem: Decodable {
        struct Track: Decodable { let uri: String? }
        let track: Track?
    }

    let items: [PlaylistTrackItem]
    let next: String?
}

private extension Array where Element == String {
    func chunked(into size: Int) -> [[String]] {
        guard size > 0 else { return [self] }
        var chunks: [[String]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            chunks.append(Array(self[index ..< end]))
            index = end
        }
        return chunks
    }
}
