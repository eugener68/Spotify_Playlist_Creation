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

    public init(service: String = "autoplaylistbuilder.tokens", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func save(_ token: SpotifyTokenSet) async throws {
        let data = try encoder.encode(token)
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
            throw KeychainError.saveFailed(status)
        }
    }

    public func load() async throws -> SpotifyTokenSet? {
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
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        return try decoder.decode(SpotifyTokenSet.self, from: data)
    }

    public func clear() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.clearFailed(status)
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
