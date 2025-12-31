import Foundation

public struct AppleMusicDeveloperTokenClient: AppleMusicDeveloperTokenProviding, Sendable {
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

    public init(configuration: Configuration, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    public func developerToken() async throws -> String {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        let currentPath = (components?.path ?? "")
        let endpoint = "apple-music/developer-token"

        if currentPath.isEmpty || currentPath == "/" {
            components?.path = "/\(endpoint)"
        } else {
            let pieces = currentPath.split(separator: "/").map(String.init)
            components?.path = "/" + (pieces + [endpoint]).joined(separator: "/")
        }

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AppleMusicDeveloperTokenClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Developer token endpoint failed" : text])
        }

        struct Payload: Decodable {
            let token: String
        }

        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return decoded.token
    }
}
