import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public struct PKCEChallenge: Sendable, Equatable {
    public enum Method: String, Sendable {
        case plain = "plain"
        case s256 = "S256"
    }

    public let verifier: String
    public let challenge: String
    public let method: Method
    public let state: String
}

public protocol PKCEGenerating: Sendable {
    func makeChallenge() -> PKCEChallenge
}

public struct PKCEGenerator: PKCEGenerating {
    private let verifierLength: Int

    public init(verifierLength: Int = 64) {
        self.verifierLength = verifierLength
    }

    public func makeChallenge() -> PKCEChallenge {
        let verifier = randomURLSafeString(length: verifierLength)
        let challenge: String
    #if canImport(CryptoKit)
        if let data = verifier.data(using: .ascii) {
            let digest = SHA256.hash(data: data)
            challenge = Self.base64URLEncode(Data(digest))
        } else {
            challenge = verifier
        }
        let method: PKCEChallenge.Method = .s256
    #else
        challenge = verifier
        let method: PKCEChallenge.Method = .plain
    #endif
        let state = randomURLSafeString(length: 32)
        return PKCEChallenge(verifier: verifier, challenge: challenge, method: method, state: state)
    }

    private func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
    #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status == errSecSuccess {
            return Self.base64URLEncode(Data(bytes))
        }
    #endif
        for index in 0..<bytes.count {
            bytes[index] = UInt8.random(in: 0...UInt8.max)
        }
        return Self.base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
