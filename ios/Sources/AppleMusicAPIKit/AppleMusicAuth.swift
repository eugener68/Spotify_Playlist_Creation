import DomainKit
import Foundation
import StoreKit
import MusicKit

public enum AppleMusicAuthError: Error, LocalizedError {
    case notAuthorized
    case userTokenUnavailable
    case storefrontUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Apple Music access is not authorized."
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

    public init(
        developerTokenProvider: AppleMusicDeveloperTokenProviding,
        userTokenStore: AppleMusicUserTokenStoring
    ) {
        self.developerTokenProvider = developerTokenProvider
        self.userTokenStore = userTokenStore
    }

    public func ensureAuthorized() async throws {
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

    public func musicUserToken() async throws -> String {
        if let cached = try await userTokenStore.load(), !cached.isEmpty {
            return cached
        }

        try await ensureAuthorized()

        let developerToken = try await developerTokenProvider.developerToken()
        let controller = SKCloudServiceController()

        let token: String = try await withCheckedThrowingContinuation { continuation in
            controller.requestUserToken(forDeveloperToken: developerToken) { userToken, error in
                if let error {
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
    }

    public func storefrontID() async throws -> String {
        try await ensureAuthorized()

        let controller = SKCloudServiceController()
        return try await withCheckedThrowingContinuation { continuation in
            controller.requestStorefrontIdentifier { storefront, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let storefront, !storefront.isEmpty else {
                    continuation.resume(throwing: AppleMusicAuthError.storefrontUnavailable)
                    return
                }
                continuation.resume(returning: storefront)
            }
        }
    }

    public func signOut() async throws {
        try await userTokenStore.clear()
    }
}
