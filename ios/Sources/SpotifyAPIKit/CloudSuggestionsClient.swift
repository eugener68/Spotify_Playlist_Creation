import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls a backend suggestions endpoint (e.g. Cloud Run) that returns Spotify artist suggestions.
public struct CloudSuggestionsClient: ArtistSuggestionProviding, Sendable {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let apiKey: String?

        public init(baseURL: URL, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(configuration: Configuration, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder = decoder
    }

    public func searchArtistSummaries(_ query: String, limit: Int) async throws -> [ArtistSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        if components?.path.isEmpty == true {
            components?.path = "/suggestions"
        }
        // If baseURL already contains a path, we keep it as-is.
        if components?.path.isEmpty != false {
            components?.path = "/suggestions"
        }

        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else {
            throw SpotifyAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.transport(URLError(.badServerResponse))
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                    throw SpotifyAPIError.api(status: httpResponse.statusCode, message: body)
                }
                throw SpotifyAPIError.unexpectedStatus(httpResponse.statusCode)
            }

            let decoded = try decoder.decode(Response.self, from: data)
            return decoded.artists.map {
                ArtistSummary(
                    id: $0.id,
                    name: $0.name,
                    followers: $0.followers,
                    genres: $0.genres,
                    imageURL: $0.imageURL
                )
            }
        } catch let error as SpotifyAPIError {
            throw error
        } catch {
            throw SpotifyAPIError.transport(error)
        }
    }
}

private extension CloudSuggestionsClient {
    struct Response: Decodable {
        let artists: [Artist]
    }

    struct Artist: Decodable {
        let id: String
        let name: String
        let followers: Int?
        let genres: [String]
        let imageURL: URL?
    }
}
