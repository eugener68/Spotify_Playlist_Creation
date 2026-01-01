import DomainKit
import Foundation
import StoreKit
import MusicKit

public enum AppleMusicAuthError: Error, LocalizedError {
    case unsupportedOnSimulator
    case notAuthorized
    case cloudServiceNotAuthorized
    case privacyAcknowledgementRequired
    case userTokenUnavailable
    case storefrontUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedOnSimulator:
            return "Apple Music is not available in the iOS Simulator. Run the app on a real iPhone/iPad signed into Apple Music."
        case .notAuthorized:
            return "Apple Music access is not authorized."
        case .cloudServiceNotAuthorized:
            return "Apple Music (Cloud Service) access is not authorized."
        case .privacyAcknowledgementRequired:
            return "Apple Music requires a privacy acknowledgement. Open the Music app once, accept any prompts/terms, then try again."
        case .userTokenUnavailable:
            return "Could not obtain Apple Music user token."
        case .storefrontUnavailable:
            return "Could not determine Apple Music storefront."
        }
    }
}

public protocol AppleMusicDeveloperTokenProviding: Sendable {
    func developerToken() async throws -> String
}

public protocol AppleMusicUserTokenStoring: Sendable {
    func load() async throws -> String?
    func save(_ token: String) async throws
    func clear() async throws
}

/// Auth + token retrieval wrapper.
///
/// Responsibilities:
/// - request MusicKit authorization
/// - obtain Music User Token using a backend-provided Developer Token
/// - obtain storefront identifier
public actor AppleMusicAuthenticator {
    private let developerTokenProvider: AppleMusicDeveloperTokenProviding
    private let userTokenStore: AppleMusicUserTokenStoring
    private let urlSession: URLSession

    public init(
        developerTokenProvider: AppleMusicDeveloperTokenProviding,
        userTokenStore: AppleMusicUserTokenStoring
    ) {
        self.developerTokenProvider = developerTokenProvider
        self.userTokenStore = userTokenStore
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    private func ensureCloudServiceAuthorized() async throws {
        let status = SKCloudServiceController.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let requested: SKCloudServiceAuthorizationStatus = await withCheckedContinuation { continuation in
                SKCloudServiceController.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
            guard requested == .authorized else {
                throw AppleMusicAuthError.cloudServiceNotAuthorized
            }
        case .denied, .restricted:
            throw AppleMusicAuthError.cloudServiceNotAuthorized
        @unknown default:
            throw AppleMusicAuthError.cloudServiceNotAuthorized
        }
    }

    public func ensureAuthorized() async throws {
        try await ensureCloudServiceAuthorized()

        let status = MusicAuthorization.currentStatus
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let requested = await MusicAuthorization.request()
            guard requested == .authorized else {
                throw AppleMusicAuthError.notAuthorized
            }
        default:
            throw AppleMusicAuthError.notAuthorized
        }
    }

    /// Returns the cached user token if present, without triggering any permission prompts.
    /// Use this for "status" checks during app launch.
    public func cachedMusicUserToken() async throws -> String? {
        let cached = try await userTokenStore.load()
        return (cached?.isEmpty == false) ? cached : nil
    }

    public func developerToken() async throws -> String {
        try await developerTokenProvider.developerToken()
    }

    public func musicUserToken() async throws -> String {
#if targetEnvironment(simulator)
        throw AppleMusicAuthError.unsupportedOnSimulator
#else
        if let cached = try await userTokenStore.load(), !cached.isEmpty {
            return cached
        }

        try await ensureAuthorized()

        let developerToken = try await developerTokenProvider.developerToken()
        let controller = SKCloudServiceController()

        let token: String = try await withCheckedThrowingContinuation { continuation in
            controller.requestUserToken(forDeveloperToken: developerToken) { userToken, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.code == -7007 {
                        continuation.resume(throwing: AppleMusicAuthError.privacyAcknowledgementRequired)
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }
                guard let userToken, !userToken.isEmpty else {
                    continuation.resume(throwing: AppleMusicAuthError.userTokenUnavailable)
                    return
                }
                continuation.resume(returning: userToken)
            }
        }

        try await userTokenStore.save(token)
        return token
#endif
    }

    public func storefrontID() async throws -> String {
#if targetEnvironment(simulator)
        throw AppleMusicAuthError.unsupportedOnSimulator
#else
        // Apple Music Web API expects a storefront like "us", "gb", etc.
        // `SKCloudServiceController.requestStorefrontIdentifier` returns an iTunes storefront identifier
        // (e.g. "143441-1,29"), which the Apple Music Web API rejects.
        let developerToken = try await developerTokenProvider.developerToken()
        let userToken = try await musicUserToken()

        guard let url = URL(string: "https://api.music.apple.com/v1/me/storefront") else {
            throw AppleMusicAuthError.storefrontUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppleMusicAuthError.storefrontUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppleMusicAuthError.storefrontUnavailable
        }

        struct Root: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }

        let decoded = try JSONDecoder().decode(Root.self, from: data)
        guard let id = decoded.data.first?.id, !id.isEmpty else {
            throw AppleMusicAuthError.storefrontUnavailable
        }
        return id.lowercased()
#endif
    }

    public func signOut() async throws {
        try await userTokenStore.clear()
    }
}
