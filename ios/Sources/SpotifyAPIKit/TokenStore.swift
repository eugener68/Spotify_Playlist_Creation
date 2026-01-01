import Foundation
#if canImport(Security)
import Security
#endif

public struct SpotifyTokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?
    public let tokenType: String

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String?,
        tokenType: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public init(
        response: SpotifyTokenResponse,
        fallbackRefreshToken: String? = nil,
        fallbackScope: String? = nil,
        issuedAt: Date = .now
    ) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? fallbackRefreshToken
        self.expiresAt = issuedAt.addingTimeInterval(response.expiresIn)
        self.scope = response.scope ?? fallbackScope
        self.tokenType = response.tokenType
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    public func willExpire(within tolerance: TimeInterval) -> Bool {
        expiresAt <= Date().addingTimeInterval(tolerance)
    }
}

public protocol SpotifyTokenStore: Sendable {
    func save(_ token: SpotifyTokenSet) async throws
    func load() async throws -> SpotifyTokenSet?
    func clear() async throws
}

public actor InMemoryTokenStore: SpotifyTokenStore {
    private var storage: SpotifyTokenSet?

    public init(initial: SpotifyTokenSet? = nil) {
        self.storage = initial
    }

    public func save(_ token: SpotifyTokenSet) async throws {
        storage = token
    }

    public func load() async throws -> SpotifyTokenSet? {
        storage
    }

    public func clear() async throws {
        storage = nil
    }
}

#if canImport(Security)
public final class KeychainTokenStore: SpotifyTokenStore {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychainQueue = DispatchQueue(label: "autoplaylistbuilder.keychain.spotify")

    public init(service: String = "autoplaylistbuilder.tokens", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func save(_ token: SpotifyTokenSet) async throws {
        let data = try encoder.encode(token)
        try await withCheckedThrowingContinuation { continuation in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(query as CFDictionary)
                let attributes: [String: Any] = query.merging([
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ]) { $1 }
                let status = SecItemAdd(attributes as CFDictionary, nil)
                guard status == errSecSuccess else {
                    continuation.resume(throwing: KeychainError.saveFailed(status))
                    return
                }
                continuation.resume()
            }
        }
    }

    public func load() async throws -> SpotifyTokenSet? {
        try await withCheckedThrowingContinuation { continuation in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    continuation.resume(returning: nil)
                    return
                }
                guard status == errSecSuccess else {
                    continuation.resume(throwing: KeychainError.loadFailed(status))
                    return
                }
                guard let data = result as? Data else {
                    continuation.resume(throwing: KeychainError.unexpectedData)
                    return
                }
                do {
                    let decoded = try decoder.decode(SpotifyTokenSet.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func clear() async throws {
        try await withCheckedThrowingContinuation { continuation in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    continuation.resume(throwing: KeychainError.clearFailed(status))
                    return
                }
                continuation.resume()
            }
        }
    }

    public enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case clearFailed(OSStatus)
        case unexpectedData
    }
}
#endif
