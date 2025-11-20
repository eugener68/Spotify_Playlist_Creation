import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SpotifyAPIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case decoding(Error)
    case transport(Error)
    case unexpectedStatus(Int)

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
        }
    }
}

public struct SpotifyAPIConfiguration {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(clientID: String, redirectURI: URL, scopes: [String]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

public final class SpotifyAPIClient: @unchecked Sendable {
    private let urlSession: URLSession
    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private let jsonDecoder: JSONDecoder

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.urlSession = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.jsonDecoder = decoder
    }

    public func currentUser(accessToken: String) async throws -> SpotifyUserProfile {
        let request = try authorizedRequest(path: "/me", accessToken: accessToken)
        return try await send(request)
    }

    private func authorizedRequest(path: String, accessToken: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.transport(URLError(.badServerResponse))
            }
            switch httpResponse.statusCode {
            case 200 ..< 300:
                do {
                    return try jsonDecoder.decode(T.self, from: data)
                } catch {
                    throw SpotifyAPIError.decoding(error)
                }
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
}
