import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SpotifyAuthorizationSession: Sendable {
    public let configuration: SpotifyAPIConfiguration
    public let codeVerifier: String
    public let state: String
    public let authorizationURL: URL
}

public struct SpotifyTokenResponse: Codable, Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let scope: String?
    public let expiresIn: TimeInterval
    public let refreshToken: String?
}

public protocol SpotifyTokenRefreshing: Sendable {
    func refreshAccessToken(refreshToken: String) async throws -> SpotifyTokenResponse
}

public final class SpotifyPKCEAuthenticator: SpotifyTokenRefreshing, Sendable {
    private let configuration: SpotifyAPIConfiguration
    private let pkceGenerator: PKCEGenerating
    private let urlSession: URLSession
    private let authorizeBaseURL = URL(string: "https://accounts.spotify.com/authorize")!
    private let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    public init(
    configuration: SpotifyAPIConfiguration,
        pkceGenerator: PKCEGenerating = PKCEGenerator(),
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.configuration = configuration
        self.pkceGenerator = pkceGenerator
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    public func makeAuthorizationSession() throws -> SpotifyAuthorizationSession {
        let pkce = pkceGenerator.makeChallenge()
        var components = URLComponents(url: authorizeBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method.rawValue)
        ]
        guard let url = components?.url else {
            throw SpotifyAPIError.invalidURL
        }
        return SpotifyAuthorizationSession(
            configuration: configuration,
            codeVerifier: pkce.verifier,
            state: pkce.state,
            authorizationURL: url
        )
    }

    public func exchangeCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> SpotifyTokenResponse {
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        return try await postTokenRequest(bodyComponents: bodyComponents)
    }

    public func refreshAccessToken(refreshToken: String) async throws -> SpotifyTokenResponse {
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: configuration.clientID)
        ]
        return try await postTokenRequest(bodyComponents: bodyComponents)
    }

    private func postTokenRequest(bodyComponents: URLComponents) async throws -> SpotifyTokenResponse {
        guard let bodyData = bodyComponents.percentEncodedQuery?.data(using: .utf8) else {
            throw SpotifyAPIError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                throw SpotifyAPIError.unauthorized
            }
            throw SpotifyAPIError.unexpectedStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        } catch {
            throw SpotifyAPIError.decoding(error)
        }
    }
}
