import Foundation
#if canImport(Security)
import Security
#endif

#if canImport(Security)
public final class KeychainAppleMusicUserTokenStore: AppleMusicUserTokenStoring {
    private let service: String
    private let account: String
    private let keychainQueue = DispatchQueue(label: "autoplaylistbuilder.keychain.applemusic")

    public init(service: String = "autoplaylistbuilder.applemusic.tokens", account: String = "current-user") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> String? {
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
                guard let token = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: KeychainError.unexpectedData)
                    return
                }
                continuation.resume(returning: token)
            }
        }
    }

    public func save(_ token: String) async throws {
        let data = Data(token.utf8)
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
