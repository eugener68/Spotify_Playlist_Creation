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
            switch httpResponse.statusCode {
            case 200 ..< 300:
                return data
            case 401:
                throw SpotifyAPIError.unauthorized
            case 429:
                let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "0"
                throw SpotifyAPIError.rateLimited(retryAfter: TimeInterval(retryAfterValue) ?? 1)
            default:
                throw SpotifyAPIError.unexpectedStatus(httpResponse.statusCode)
            }
        } catch let error as SpotifyAPIError {
            throw error
        } catch {
            throw SpotifyAPIError.transport(error)
        }
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
