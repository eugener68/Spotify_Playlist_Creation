import Combine
import Foundation
import AppleMusicAPIKit

@MainActor
public final class AppleMusicAuthenticationViewModel: ObservableObject {
    public enum Status: Equatable {
        case unavailable
        case unknown
        case signedOut
        case signingIn
        case signedIn
    }

    @Published public private(set) var status: Status
    @Published public private(set) var lastError: String?
    @Published public private(set) var storefrontID: String?

    private let authenticator: AppleMusicAuthenticator?

    public init(authenticator: AppleMusicAuthenticator?) {
        self.authenticator = authenticator
        self.status = authenticator == nil ? .unavailable : .unknown
    }

    public func ensureStatusLoaded() async {
        guard let authenticator else {
            status = .unavailable
            return
        }
        guard status == .unknown else { return }

        do {
            // If we can load a token, consider the user connected.
            // This does not validate subscription; that happens during actual API calls.
            let token = try await authenticator.musicUserToken()
            status = token.isEmpty ? .signedOut : .signedIn
            storefrontID = try? await authenticator.storefrontID()
            lastError = nil
        } catch {
            status = .signedOut
            lastError = error.localizedDescription
        }
    }

    public func connect() async {
        guard let authenticator else {
            status = .unavailable
            return
        }
        status = .signingIn
        lastError = nil

        do {
            _ = try await authenticator.musicUserToken()
            storefrontID = try await authenticator.storefrontID()
            status = .signedIn
        } catch {
            status = .signedOut
            lastError = error.localizedDescription
        }
    }

    public func signOut() async {
        guard let authenticator else {
            status = .unavailable
            return
        }
        do {
            try await authenticator.signOut()
            storefrontID = nil
            status = .signedOut
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
