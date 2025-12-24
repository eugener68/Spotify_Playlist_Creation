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

        var components = endpointComponents(endpointName: "suggestions")

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

extension CloudSuggestionsClient: ArtistIdeasProviding {
    public func generateArtistIdeas(prompt: String, artistCount: Int, userId: String?) async throws -> [ArtistSummary] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let components = endpointComponents(endpointName: "artist-ideas")
        guard let url = components?.url else {
            throw SpotifyAPIError.invalidURL
        }

        struct RequestBody: Encodable {
            let prompt: String
            let artistCount: Int
            let userId: String?
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        do {
            let body = try JSONEncoder().encode(
                RequestBody(
                    prompt: trimmed,
                    artistCount: artistCount,
                    userId: userId
                )
            )
            request.httpBody = body

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.transport(URLError(.badServerResponse))
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if let bodyText = String(data: data, encoding: .utf8), !bodyText.isEmpty {
                    throw SpotifyAPIError.api(status: httpResponse.statusCode, message: bodyText)
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
    func endpointComponents(endpointName: String) -> URLComponents? {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        let endpoint = endpointName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let currentPath = (components?.path ?? "")

        if currentPath.isEmpty || currentPath == "/" {
            components?.path = "/\(endpoint)"
            return components
        }

        let pieces = currentPath.split(separator: "/").map(String.init)
        guard !pieces.isEmpty else {
            components?.path = "/\(endpoint)"
            return components
        }

        var updated = pieces
        if updated.last == "suggestions" || updated.last == "artist-ideas" {
            updated[updated.count - 1] = endpoint
        } else {
            updated.append(endpoint)
        }
        components?.path = "/" + updated.joined(separator: "/")
        return components
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
