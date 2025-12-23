import Combine
import Foundation
import SpotifyAPIKit

@MainActor
public final class AuthenticationViewModel: ObservableObject {
    public enum Status: Equatable {
        case unavailable
        case unknown
        case signedOut
        case signingIn
        case signedIn
    }

    public enum FlowError: LocalizedError {
        case unavailable
        case missingSession
        case missingCallback
        case remoteError(String)
        case stateMismatch

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Authentication is not available in this build."
            case .missingSession:
                return "Authentication session is no longer active."
            case .missingCallback:
                return "Authentication did not return a valid response."
            case .remoteError(let message):
                return "Spotify authorization failed: \(message)."
            case .stateMismatch:
                return "Authentication could not be verified. Please try again."
            }
        }
    }

    @Published public private(set) var status: Status
    @Published public private(set) var lastError: String?

    public var requiresAuthentication: Bool { authentication != nil }
    public var isAuthenticated: Bool { status == .signedIn }
    public var isBusy: Bool { status == .signingIn }

    private let authentication: AppDependencies.Authentication?
    private var pendingSession: SpotifyAuthorizationSession?

    public init(authentication: AppDependencies.Authentication?) {
        self.authentication = authentication
        self.status = authentication == nil ? .unavailable : .unknown
    }

    public func ensureStatusLoaded() async {
        guard let authentication else {
            status = .unavailable
            return
        }
        guard status == .unknown else { return }
        await refreshStatus(authentication: authentication)
    }

    private func refreshStatus(authentication: AppDependencies.Authentication) async {
        do {
            let token = try await authentication.tokenStore.load()
            status = token == nil ? .signedOut : .signedIn
            lastError = nil
        } catch {
            status = .signedOut
            lastError = error.localizedDescription
        }
    }

    public func beginAuthorization() throws -> SpotifyAuthorizationSession {
        guard let authentication else {
            throw FlowError.unavailable
        }
        let session = try authentication.authenticator.makeAuthorizationSession()
        pendingSession = session
        status = .signingIn
        lastError = nil
        return session
    }

    public func handleRedirect(url: URL) async {
        guard let authentication else {
            status = .unavailable
            return
        }
        guard let pendingSession else {
            status = .signedOut
            lastError = FlowError.missingSession.errorDescription
            return
        }
        do {
            let payload = try Self.parseCallback(url: url)
            guard payload.state == pendingSession.state else {
                throw FlowError.stateMismatch
            }
            let response = try await authentication.authenticator.exchangeCode(
                payload.code,
                codeVerifier: pendingSession.codeVerifier
            )
            let tokenSet = SpotifyTokenSet(response: response)
            _ = try await authentication.tokenProvider.update(token: tokenSet)
            status = .signedIn
            lastError = nil
        } catch {
            status = .signedOut
            lastError = error.localizedDescription
        }
        self.pendingSession = nil
    }

    public func handleAuthorizationFailure(error: Error) async {
        pendingSession = nil
        status = .signedOut
        lastError = error.localizedDescription
    }

    public func handleAuthorizationCancellation() async {
        pendingSession = nil
        status = .signedOut
        lastError = nil
    }

    public func signOut() async {
        guard let authentication else {
            status = .unavailable
            return
        }
        do {
            try await authentication.tokenProvider.clear()
            status = .signedOut
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct CallbackPayload {
        let code: String
        let state: String
    }

    private static func parseCallback(url: URL) throws -> CallbackPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FlowError.missingCallback
        }
        if let remoteError = components.value(for: "error") {
            if let description = components.value(for: "error_description") {
                throw FlowError.remoteError("\(remoteError): \(description)")
            }
            throw FlowError.remoteError(remoteError)
        }
        guard let code = components.value(for: "code"),
              let state = components.value(for: "state") else {
            throw FlowError.missingCallback
        }
        return CallbackPayload(code: code, state: state)
    }
}

private extension URLComponents {
    func value(for name: String) -> String? {
        queryItems?.first(where: { $0.name == name })?.value
    }
}
