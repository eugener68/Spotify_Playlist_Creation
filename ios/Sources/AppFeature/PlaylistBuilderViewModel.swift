import Combine
import Foundation
import DomainKit
import AppleMusicAPIKit

@MainActor
public final class PlaylistBuilderViewModel: ObservableObject {
    public enum Destination: Sendable {
        case spotify
        case appleMusic
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastResult: PlaylistResult?
    @Published public private(set) var errorMessage: String?

    private let playlistBuilder: PlaylistBuilder
    private var buildTask: Task<Void, Never>?

    public init(playlistBuilder: PlaylistBuilder) {
        self.playlistBuilder = playlistBuilder
    }

    deinit {
        buildTask?.cancel()
    }

    public func run(options: PlaylistOptions, destination: Destination = .spotify, appleMusicClient: AppleMusicAPIClient? = nil) {
        buildTask?.cancel()
        errorMessage = nil
        isRunning = true

        buildTask = Task { [weak self] in
            guard let self else { return }
            await self.performBuild(options: options, destination: destination, appleMusicClient: appleMusicClient)
        }
    }

    private func performBuild(options: PlaylistOptions, destination: Destination, appleMusicClient: AppleMusicAPIClient?) async {
        defer { isRunning = false }
        do {
            switch destination {
            case .spotify:
                let context = PlaylistBuilderContext(options: options)
                let result = try await playlistBuilder.build(with: context)
                lastResult = result
            case .appleMusic:
                guard let appleMusicClient else {
                    throw NSError(domain: "PlaylistBuilderViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Music client is unavailable."])
                }

                // Build the track list via Spotify pipeline, but avoid writing to Spotify.
                var spotifyOptions = options
                spotifyOptions.dryRun = true
                spotifyOptions.reuseExisting = false

                let context = PlaylistBuilderContext(options: spotifyOptions)
                let spotifyResult = try await playlistBuilder.build(with: context)

                let created = try await appleMusicClient.createPlaylist(from: spotifyResult.draft)
                let appleMusicUploadURIs = created.addedSongIDs.map { "applemusic:song:\($0)" }

                let updatedStats = PlaylistStats(
                    playlistName: spotifyResult.stats.playlistName,
                    artistsRetrieved: spotifyResult.stats.artistsRetrieved,
                    topTracksRetrieved: spotifyResult.stats.topTracksRetrieved,
                    variantsDeduped: spotifyResult.stats.variantsDeduped,
                    totalPrepared: spotifyResult.stats.totalPrepared,
                    totalUploaded: options.dryRun ? 0 : created.addedSongIDs.count
                )

                let finalResult = PlaylistResult(
                    playlistID: created.playlistID,
                    playlistName: spotifyResult.playlistName,
                    preparedTrackURIs: spotifyResult.preparedTrackURIs,
                    addedTrackURIs: spotifyResult.addedTrackURIs,
                    finalUploadURIs: options.dryRun ? [] : appleMusicUploadURIs,
                    displayTracks: spotifyResult.displayTracks,
                    draft: spotifyResult.draft,
                    dryRun: options.dryRun,
                    reusedExisting: false,
                    stats: updatedStats
                )

                lastResult = finalResult
            }
        } catch is CancellationError {
            // Ignore cancellation because a new run has been requested.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
