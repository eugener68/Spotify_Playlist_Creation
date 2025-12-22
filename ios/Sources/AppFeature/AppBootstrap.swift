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
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
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
    enum FlowStep: Int, CaseIterable, Identifiable {
        case authentication
        case options
        case creation
        case results

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .authentication: return L10n.Flow.signIn
            case .options: return L10n.Flow.settings
            case .creation: return L10n.Flow.build
            case .results: return L10n.Flow.results
            }
        }

        var systemImage: String {
            switch self {
            case .authentication: return "person.crop.circle.fill"
            case .options: return "slider.horizontal.3"
            case .creation: return "music.note.list"
            case .results: return "sparkles"
            }
        }
    }

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
    @State private var playlistName: String = L10n.Builder.defaultPlaylistName
    @State private var manualArtists: String = "Metallica, A-ha"
    @State private var limitPerArtist: Int = 3
    @State private var maxTracks: Int = 10
    @State private var shuffle: Bool = true
    @State private var preferOriginalTracks: Bool = true
    @Environment(\.openURL) private var openURLAction
    @State private var dateStamp: Bool = true
    @State private var dryRun: Bool = true
    @State private var isImportingArtists = false
    @State private var activeStep: FlowStep = .authentication
    @State private var artistInputFeedback: String?
    @ObservedObject private var localization = LocalizationController.shared
    #if canImport(AuthenticationServices)
    @State private var webAuthSession: ASWebAuthenticationSession?
    private let presentationContextProvider = DefaultWebAuthenticationPresentationContextProvider()
    #endif
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        ZStack {
            AppSurfaceBackground()
            VStack(spacing: 20) {
                FlowStepSelector(
                    activeStep: $activeStep,
                    isAuthenticated: authViewModel.isAuthenticated,
                    requiresAuthentication: authViewModel.requiresAuthentication,
                    hasResults: viewModel.lastResult != nil
                )
                .padding(Edge.Set.top, 8)

                screenContent()

                if activeStep == .creation {
                    buildActionPanel()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: authViewModel.isAuthenticated) { _ in
            updateActiveStepForAuth()
        }
        .onChange(of: authViewModel.requiresAuthentication) { _ in
            updateActiveStepForAuth()
        }
        .onChange(of: viewModel.lastResult) { result in
            if result != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    activeStep = .results
                }
            }
        }
        .task {
            await authViewModel.ensureStatusLoaded()
            updateActiveStepForAuth()
        }
        .fileImporter(
            isPresented: $isImportingArtists,
            allowedContentTypes: artistImportContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleArtistImport(result:)
        )
    }

    @ViewBuilder
    private func screenContent() -> some View {
        switch activeStep {
        case .authentication:
            authenticationCard
        case .options:
            optionsScreen
        case .creation:
            createPlaylistCards
        case .results:
            resultsCard
        }
    }

    private var authenticationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Builder.spotifyAccountTitle)
                .font(.title2.bold())
            authenticationSection()
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 12, y: 6)
    }

    private var createPlaylistCards: some View {
        ScrollView {
            VStack(spacing: 18) {
                playlistCard
                artistsCard
            }
            .padding(.bottom)
        }
    }

    private var optionsScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                optionsCard
            }
            .padding(.bottom)
        }
    }

    private var resultsCard: some View {
        Group {
            if let result = viewModel.lastResult {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.Builder.latestBuildTitle)
                        .font(.title3.bold())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.playlistName)
                            .font(.headline)
                        Text(L10n.Results.preparedAndUploaded(prepared: result.preparedTrackURIs.count, uploaded: result.stats.totalUploaded))
                            .font(.subheadline)
                        Text(result.reusedExisting ? L10n.Results.updatedExisting : L10n.Results.createdNew)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(L10n.Builder.uploadOrderTitle)
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(displayRows(for: result)) { row in
                                UploadRowView(index: row.index, primaryText: row.primary, secondaryText: row.secondary)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            } else {
                emptyResultsPlaceholder
            }
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 12, y: 6)
    }

    @ViewBuilder
    private var emptyResultsPlaceholder: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            ContentUnavailableView(LocalizedStringKey(L10n.Builder.emptyResultsTitle), systemImage: "sparkles", description: Text(L10n.Builder.emptyResultsDescription))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L10n.Builder.emptyResultsTitle)
                    .font(.headline)
                Text(L10n.Builder.emptyResultsDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func buildActionPanel() -> some View {
        VStack(spacing: 12) {
            Button(action: runBuild) {
                Label {
                    Text(viewModel.isRunning ? L10n.Builder.buildingButton : L10n.Builder.runButton)
                } icon: {
                    Image(systemName: "play.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(viewModel.isRunning || parsedManualQueries().isEmpty || isAuthenticationRequiredButUnavailable)

            if viewModel.isRunning {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 12, y: 6)
    }

    private var playlistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Builder.playlistNameLabel)
                .font(.title3.bold())
            TextField(L10n.Builder.playlistNamePlaceholder, text: $playlistName)
                .filledTextFieldStyle()
            OptionToggleRow(title: L10n.Builder.dateStampToggle, subtitle: nil, isOn: $dateStamp)
            OptionToggleRow(title: L10n.Builder.dryRunToggle, subtitle: nil, isOn: $dryRun)
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 10, y: 4)
    }

    private var artistsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Builder.manualArtistListTitle)
                .font(.title3.bold())
            TextEditor(text: $manualArtists)
                .frame(minHeight: 110)
                .padding(10)
                .background(editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(L10n.Builder.manualArtistHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(action: { isImportingArtists = true }) {
                    Label {
                        Text(L10n.Builder.importArtistList)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button(action: pasteArtistsFromClipboard) {
                    Label {
                        Text(L10n.Builder.pasteArtistList)
                    } icon: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(pasteboardString == nil)
            }
            if let artistInputFeedback {
                Text(artistInputFeedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 10, y: 4)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.Builder.settingsTitle)
                .font(.title3.bold())
            LanguageSelectorRow(selection: $localization.selection)
            OptionStepperRow(
                title: L10n.Builder.limitPerArtistTitle,
                subtitle: L10n.Builder.limitPerArtistSubtitle,
                value: $limitPerArtist,
                bounds: 1...10
            )
            OptionStepperRow(
                title: L10n.Builder.maxTracksTitle,
                subtitle: L10n.Builder.maxTracksSubtitle,
                value: $maxTracks,
                bounds: 1...100
            )
            OptionToggleRow(
                title: L10n.Builder.shuffleTitle,
                subtitle: L10n.Builder.shuffleSubtitle,
                isOn: $shuffle
            )
            OptionToggleRow(
                title: L10n.Builder.preferOriginalTitle,
                subtitle: L10n.Builder.preferOriginalSubtitle,
                isOn: $preferOriginalTracks
            )
        }
        .padding()
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: shadowColor, radius: 10, y: 4)
    }

    private func displayRows(for result: PlaylistResult) -> [DisplayRow] {
        if result.displayTracks.isEmpty {
            return result.finalUploadURIs.enumerated().map { DisplayRow(index: $0.offset, primary: $0.element, secondary: $0.element) }
        }
        return result.displayTracks.enumerated().map { index, text in
            let secondary = index < result.finalUploadURIs.count ? result.finalUploadURIs[index] : nil
            return DisplayRow(index: index, primary: text, secondary: secondary)
        }
    }

    private func buildCardBackgroundColor() -> Color {
        colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.18) : Color.white.opacity(0.96)
    }

    private var cardBackground: Color { buildCardBackgroundColor() }

    private var editorBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.08)
    }

    private func updateActiveStepForAuth() {
        if authViewModel.requiresAuthentication && !authViewModel.isAuthenticated {
            activeStep = .authentication
        } else if activeStep == .authentication {
            activeStep = .options
        }
    }

    private func parsedManualQueries() -> [String] {
        parseArtistList(manualArtists)
    }

    private func pasteArtistsFromClipboard() {
        guard let clipboardString = pasteboardString else {
            artistInputFeedback = L10n.ArtistInput.clipboardEmpty
            return
        }
        let added = appendArtists(from: clipboardString)
        artistInputFeedback = added > 0 ? L10n.ArtistInput.clipboardAdded(added) : L10n.ArtistInput.clipboardNone
    }

    private func handleArtistImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
        #if os(iOS)
            guard url.startAccessingSecurityScopedResource() else {
                artistInputFeedback = L10n.ArtistInput.importPermissionDenied(url.lastPathComponent)
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
        #endif
            do {
                let data = try Data(contentsOf: url)
                guard let contents = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
                    artistInputFeedback = L10n.ArtistInput.importReadFailed(url.lastPathComponent)
                    return
                }
                let added = appendArtists(from: contents)
                artistInputFeedback = added > 0 ? L10n.ArtistInput.importAddedFromFile(added, fileName: url.lastPathComponent) : L10n.ArtistInput.importNoneInFile(url.lastPathComponent)
            } catch {
                artistInputFeedback = L10n.ArtistInput.importFailed(error.localizedDescription)
            }
        case .failure(let error):
            artistInputFeedback = L10n.ArtistInput.importFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func appendArtists(from text: String) -> Int {
        let existing = parseArtistList(manualArtists)
        var merged = existing
        var seen = Set(existing.map { $0.lowercased() })
        var addedCount = 0
        for artist in parseArtistList(text) {
            let key = artist.lowercased()
            if seen.insert(key).inserted {
                merged.append(artist)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return 0 }
        manualArtists = merged.joined(separator: "\n")
        return addedCount
    }

    private func parseArtistList(_ text: String) -> [String] {
        let sanitized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let separators = CharacterSet(charactersIn: ",;\n")
        let rawComponents = sanitized.components(separatedBy: separators)
        var seen = Set<String>()
        var results: [String] = []
        for component in rawComponents {
            var trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                results.append(trimmed)
            }
        }
        return results
    }

    private var pasteboardString: String? {
    #if canImport(UIKit)
        UIPasteboard.general.string
    #elseif os(macOS)
        NSPasteboard.general.string(forType: .string)
    #else
        nil
    #endif
    }

    private var artistImportContentTypes: [UTType] {
        if #available(iOS 16.0, macOS 13.0, *) {
            return [.commaSeparatedText, .plainText, .utf8PlainText]
        }
        return [.commaSeparatedText, .plainText]
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
                Text(L10n.Auth.statusChecking)
                    .font(.footnote)
            }
        case .signingIn:
            HStack {
                ProgressView()
                Text(L10n.Auth.statusSigningIn)
                    .font(.footnote)
            }
            Button(action: cancelAuthenticationFlow) {
                Text(L10n.Auth.cancel)
            }
                .frame(maxWidth: .infinity)
        case .signedIn:
            Label {
                Text(L10n.Auth.signedIn)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
                .foregroundColor(.green)
            Button(action: openSpotifyDashboard) {
                Label {
                    Text(L10n.Auth.openDashboard)
                } icon: {
                    Image(systemName: "safari")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button(action: signOut) {
                Text(L10n.Auth.signOut)
            }
                .frame(maxWidth: .infinity)
        case .signedOut:
            Button(action: startAuthenticationFlow) {
                Label {
                    Text(L10n.Auth.signIn)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                    .frame(maxWidth: .infinity)
            }
        case .unavailable:
            Text(L10n.Auth.unavailable)
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

    private func openSpotifyDashboard() {
        guard let fallback = URL(string: "https://www.spotify.com/account/overview") else { return }
        if let appURL = URL(string: "spotify://") {
            openURLAction(appURL) { accepted in
                if !accepted {
                    openURLAction(fallback)
                }
            }
            return
        }
        openURLAction(fallback)
    }
}
#if DEBUG
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView(dependencies: .demo())
    }
}
#endif

private struct OptionStepperRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Int
    let bounds: ClosedRange<Int>

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("\(value)")
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 32, alignment: .trailing)
                    Stepper("", value: $value, in: bounds)
                        .labelsHidden()
                }
            }
        }
        .padding(12)
        .background(optionRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var optionRowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }
}

private struct OptionToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
        .padding(12)
        .background(optionRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var optionRowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }
}

private struct LanguageSelectorRow: View {
    @Binding var selection: LocalizationOption
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.languageTitle)
                .font(.subheadline.weight(.semibold))
            Picker(L10n.Settings.languageTitle, selection: $selection) {
                Text(L10n.Settings.languageSystem).tag(LocalizationOption.system)
                Text(L10n.Settings.languageEnglish).tag(LocalizationOption.english)
                Text(L10n.Settings.languageRussian).tag(LocalizationOption.russian)
            }
            .pickerStyle(.segmented)
        }
        .padding(12)
        .background(optionRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var optionRowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }
}

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

private struct DisplayRow: Identifiable {
    let index: Int
    let primary: String
    let secondary: String?
    var id: Int { index }
}

private struct FlowStepSelector: View {
    @Binding var activeStep: RootView.FlowStep
    let isAuthenticated: Bool
    let requiresAuthentication: Bool
    let hasResults: Bool

    private var steps: [RootView.FlowStep] {
        RootView.FlowStep.allCases.filter { step in
            !(step == .authentication && !requiresAuthentication)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 86, maximum: 130), spacing: 12)]
    }

    private func isEnabled(_ step: RootView.FlowStep) -> Bool {
        switch step {
        case .authentication:
            return true
        case .options, .creation:
            return !requiresAuthentication || isAuthenticated
        case .results:
            return hasResults
        }
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
            ForEach(steps) { step in
                Button(action: { activeStep = step }) {
                    VStack(spacing: 8) {
                        Image(systemName: step.systemImage)
                        Text(step.title)
                            .font(.footnote)
                            .fontWeight(activeStep == step ? .bold : .regular)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .top)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(activeStep == step ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(activeStep == step ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                    .opacity(isEnabled(step) ? 1 : 0.4)
                }
                .disabled(!isEnabled(step))
            }
        }
    }
}

private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .foregroundColor(.white)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
            )
            .foregroundColor(.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct FilledTextFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fieldFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 6, y: 3)
    }

    private var fieldFillColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.08)
        }
        return .white
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.12)
    }
}

private extension View {
    func filledTextFieldStyle() -> some View {
        modifier(FilledTextFieldModifier())
    }
}

private struct AppSurfaceBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.14, blue: 0.08), Color(red: 0.01, green: 0.05, blue: 0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [Color(red: 0.88, green: 0.97, blue: 0.90), Color(red: 0.94, green: 0.99, blue: 0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
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
