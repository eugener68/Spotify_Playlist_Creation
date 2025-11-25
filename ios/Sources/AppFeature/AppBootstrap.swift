import Foundation
import DomainKit
import SpotifyAPIKit
#if canImport(SwiftUI)
import SwiftUI
#if canImport(AuthenticationServices)
import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif
#endif

public struct AppDependencies {
    public var playlistBuilder: PlaylistBuilder
    public var apiClient: SpotifyAPIClient
    public var authentication: Authentication?

    public struct Authentication {
        public let authenticator: SpotifyPKCEAuthenticator
        public let tokenStore: SpotifyTokenStore
        public let tokenProvider: RefreshingAccessTokenProvider

        public init(
            authenticator: SpotifyPKCEAuthenticator,
            tokenStore: SpotifyTokenStore,
            tokenProvider: RefreshingAccessTokenProvider
        ) {
            self.authenticator = authenticator
            self.tokenStore = tokenStore
            self.tokenProvider = tokenProvider
        }
    }

    public init(
        playlistBuilder: PlaylistBuilder,
        apiClient: SpotifyAPIClient,
        authentication: Authentication? = nil
    ) {
        self.playlistBuilder = playlistBuilder
        self.apiClient = apiClient
        self.authentication = authentication
    }

    public static func live(
        configuration: SpotifyAPIConfiguration,
        tokenProvider: SpotifyAccessTokenProviding
    ) -> AppDependencies {
        let apiClient = SpotifyAPIClient(
            configuration: configuration,
            tokenProvider: tokenProvider
        )
        let builderDependencies = PlaylistBuilderDependencies(
            profileProvider: apiClient,
            artistProvider: apiClient,
            trackProvider: apiClient,
            playlistEditor: apiClient
        )
        let builder = PlaylistBuilder(dependencies: builderDependencies)
        return AppDependencies(playlistBuilder: builder, apiClient: apiClient)
    }

    public static func preview() -> AppDependencies {
        let configuration = SpotifyAPIConfiguration(
            clientID: "preview-client",
            redirectURI: URL(string: "autoplaylistbuilder://callback")!,
            scopes: ["playlist-modify-private", "user-read-email"]
        )
        let tokenSet = SpotifyTokenSet(
            accessToken: "preview-access-token",
            refreshToken: "preview-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            scope: configuration.scopes.joined(separator: " "),
            tokenType: "Bearer"
        )
        let tokenStore = InMemoryTokenStore(initial: tokenSet)
        let authenticator = SpotifyPKCEAuthenticator(configuration: configuration)
        return .liveWithPKCE(
            configuration: configuration,
            tokenStore: tokenStore,
            authenticator: authenticator
        )
    }

    public static func liveWithPKCE(
        configuration: SpotifyAPIConfiguration,
        tokenStore: SpotifyTokenStore,
        authenticator: SpotifyPKCEAuthenticator
    ) -> AppDependencies {
        let provider = RefreshingAccessTokenProvider(
            tokenStore: tokenStore,
            refresher: authenticator
        )
        let apiClient = SpotifyAPIClient(
            configuration: configuration,
            tokenProvider: provider
        )
        let builderDependencies = PlaylistBuilderDependencies(
            profileProvider: apiClient,
            artistProvider: apiClient,
            trackProvider: apiClient,
            playlistEditor: apiClient
        )
        return AppDependencies(
            playlistBuilder: PlaylistBuilder(dependencies: builderDependencies),
            apiClient: apiClient,
            authentication: Authentication(
                authenticator: authenticator,
                tokenStore: tokenStore,
                tokenProvider: provider
            )
        )
    }

#if canImport(Security)
    /// Builds live dependencies that persist credentials inside the Keychain and refresh them via PKCE.
    /// - Parameters:
    ///   - configuration: Spotify client configuration.
    ///   - service: Keychain service name override for multi-app environments.
    ///   - account: Keychain account key override for multi-user environments.
    public static func liveUsingKeychain(
        configuration: SpotifyAPIConfiguration,
        service: String = "autoplaylistbuilder.tokens",
        account: String = "current-user"
    ) -> AppDependencies {
        let tokenStore = KeychainTokenStore(service: service, account: account)
        let authenticator = SpotifyPKCEAuthenticator(configuration: configuration)
        return .liveWithPKCE(
            configuration: configuration,
            tokenStore: tokenStore,
            authenticator: authenticator
        )
    }
#endif
}

#if canImport(SwiftUI)
public struct RootView: View {
    public init(dependencies: AppDependencies) {
        _viewModel = StateObject(wrappedValue: PlaylistBuilderViewModel(playlistBuilder: dependencies.playlistBuilder))
        _authViewModel = StateObject(wrappedValue: AuthenticationViewModel(authentication: dependencies.authentication))
    }

#if canImport(Security)
    /// Convenience initializer for app targets that want turnkey PKCE + Keychain wiring.
    /// Pass your Spotify configuration and (optionally) override the Keychain identifiers.
    public init(
        configuration: SpotifyAPIConfiguration,
        keychainService: String = "autoplaylistbuilder.tokens",
        keychainAccount: String = "current-user"
    ) {
        self.init(
            dependencies: .liveUsingKeychain(
                configuration: configuration,
                service: keychainService,
                account: keychainAccount
            )
        )
    }
#endif

    @StateObject private var viewModel: PlaylistBuilderViewModel
    @StateObject private var authViewModel: AuthenticationViewModel
    @State private var playlistName: String = "My Playlist"
    @State private var manualArtists: String = "Metallica, A-ha"
    @State private var limitPerArtist: Int = 3
    @State private var maxTracks: Int = 10
    @State private var shuffle: Bool = false
    @State private var preferOriginalTracks: Bool = true
    @State private var dateStamp: Bool = true
    @State private var dryRun: Bool = true
    #if canImport(AuthenticationServices)
    @State private var webAuthSession: ASWebAuthenticationSession?
    private let presentationContextProvider = DefaultWebAuthenticationPresentationContextProvider()
    #endif

    public var body: some View {
        NavigationView {
            Form {
                if authViewModel.requiresAuthentication {
                    Section("Spotify Account") {
                        authenticationSection()
                    }
                }

                Section("Playlist Name \n(replace default name with desired one)") {
                    TextField("Playlist name", text: $playlistName)
                    Toggle("Date stamp name", isOn: $dateStamp)
                    Toggle("Dry run", isOn: $dryRun)
                }

                Section("Manual artists") {
                    TextEditor(text: $manualArtists)
                        .frame(minHeight: 80)
                    Text("Separate artists with commas or new lines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Demo data ships with Metallica and A-ha")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Options") {
                    Stepper(value: $limitPerArtist, in: 1 ... 10) {
                        Label("Limit per artist: \(limitPerArtist)", systemImage: "music.note.list")
                    }
                    Stepper(value: $maxTracks, in: 1 ... 100) {
                        Label("Max tracks: \(maxTracks)", systemImage: "number.square")
                    }
                    Toggle("Shuffle results", isOn: $shuffle)
                    Toggle("Prefer original versions", isOn: $preferOriginalTracks)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(action: runBuild) {
                        Label(viewModel.isRunning ? "Building…" : "Run Playlist Build", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isRunning || parsedManualQueries().isEmpty || isAuthenticationRequiredButUnavailable)

                    if viewModel.isRunning {
                        ProgressView()
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if let result = viewModel.lastResult {
                    Section("Latest Result") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.playlistName)
                                .font(.headline)
                            Text("Prepared: \(result.preparedTrackURIs.count) – Uploaded: \(result.stats.totalUploaded)")
                                .font(.subheadline)
                            Text("Reused existing playlist: \(result.reusedExisting ? "Yes" : "No")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Upload Order (\(result.finalUploadURIs.count))") {
                        if result.displayTracks.isEmpty {
                            ForEach(Array(result.finalUploadURIs.enumerated()), id: \.offset) { index, uri in
                                UploadRowView(
                                    index: index,
                                    primaryText: uri,
                                    secondaryText: uri
                                )
                            }
                        } else {
                            ForEach(Array(result.displayTracks.enumerated()), id: \.offset) { index, description in
                                UploadRowView(
                                    index: index,
                                    primaryText: description,
                                    secondaryText: index < result.finalUploadURIs.count ? result.finalUploadURIs[index] : nil
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Spotify Playlist Builder")
        }
        .task {
            await authViewModel.ensureStatusLoaded()
        }
    #if os(iOS)
        .navigationViewStyle(.stack)
    #endif
    }

    private func parsedManualQueries() -> [String] {
        manualArtists
            .split(whereSeparator: { character in
                character == "," || character == "\n"
            })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runBuild() {
        let queries = parsedManualQueries()
        guard !queries.isEmpty else { return }
        guard !isAuthenticationRequiredButUnavailable else { return }
        let options = PlaylistOptions(
            playlistName: playlistName,
            dateStamp: dateStamp,
            limitPerArtist: limitPerArtist,
            maxArtists: max(queries.count, 1),
            maxTracks: maxTracks,
            shuffle: shuffle,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: false,
            truncate: false,
            verbose: false,
            dryRun: dryRun,
            preferOriginalTracks: preferOriginalTracks,
            manualArtistQueries: queries,
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )
        viewModel.run(options: options)
    }

    private var isAuthenticationRequiredButUnavailable: Bool {
        authViewModel.requiresAuthentication && !authViewModel.isAuthenticated
    }

    @ViewBuilder
    private func authenticationSection() -> some View {
        switch authViewModel.status {
        case .unknown:
            HStack {
                ProgressView()
                Text("Checking existing session…")
                    .font(.footnote)
            }
        case .signingIn:
            HStack {
                ProgressView()
                Text("Waiting for Spotify sign-in…")
                    .font(.footnote)
            }
            Button("Cancel", action: cancelAuthenticationFlow)
                .frame(maxWidth: .infinity)
        case .signedIn:
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Button("Sign out", action: signOut)
                .frame(maxWidth: .infinity)
        case .signedOut:
            Button(action: startAuthenticationFlow) {
                Label("Sign in with Spotify", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
        case .unavailable:
            Text("Authentication unavailable in this build.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let error = authViewModel.lastError {
            Text(error)
                .font(.footnote)
                .foregroundColor(.red)
        }
    }

    private func startAuthenticationFlow() {
        guard authViewModel.requiresAuthentication else { return }
    #if canImport(AuthenticationServices)
        do {
            let session = try authViewModel.beginAuthorization()
            let webSession = ASWebAuthenticationSession(
                url: session.authorizationURL,
                callbackURLScheme: session.configuration.redirectURI.scheme
            ) { callbackURL, error in
                Task { @MainActor in
                    self.webAuthSession = nil
                }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    Task { await authViewModel.handleAuthorizationCancellation() }
                    return
                }
                if let error {
                    Task { await authViewModel.handleAuthorizationFailure(error: error) }
                    return
                }
                guard let callbackURL else {
                    Task { await authViewModel.handleAuthorizationFailure(error: AuthenticationViewModel.FlowError.missingCallback) }
                    return
                }
                Task { await authViewModel.handleRedirect(url: callbackURL) }
            }
            webSession.prefersEphemeralWebBrowserSession = true
        #if os(iOS) || os(macOS)
            webSession.presentationContextProvider = presentationContextProvider
        #endif
            webSession.start()
            webAuthSession = webSession
        } catch {
            Task { await authViewModel.handleAuthorizationFailure(error: error) }
        }
    #else
        Task { await authViewModel.handleAuthorizationFailure(error: AuthenticationViewModel.FlowError.unavailable) }
    #endif
    }

    private func cancelAuthenticationFlow() {
    #if canImport(AuthenticationServices)
        webAuthSession?.cancel()
        webAuthSession = nil
    #endif
        Task { await authViewModel.handleAuthorizationCancellation() }
    }

    private func signOut() {
        Task { await authViewModel.signOut() }
    }
}
#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView(dependencies: .demo())
    }
}
#endif

private struct UploadRowView: View {
    let index: Int
    let primaryText: String
    let secondaryText: String?

    @State private var showSecondary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1). \(primaryText)")
                .font(.caption)
            if showSecondary, let secondaryText {
                Text(secondaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSecondary.toggle()
            }
        }
    }
}
#endif

#if canImport(SwiftUI) && canImport(AuthenticationServices)
private final class DefaultWebAuthenticationPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
