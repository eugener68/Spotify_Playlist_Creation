import Foundation

public enum PlaylistBuilderError: Error, LocalizedError {
    case missingUserID
    case noArtistsResolved
    case noTracksResolved
    case artistsFileMissing(String)
    case underlying(Error)
    case missingDependencies

    public var errorDescription: String? {
        switch self {
        case .missingUserID:
            return "Spotify profile did not include a user identifier."
        case .noArtistsResolved:
            return "No artists were resolved from the configured sources."
        case .noTracksResolved:
            return "No tracks could be generated for the playlist."
        case let .artistsFileMissing(path):
            return "Artists file \(path) does not exist."
        case let .underlying(error):
            return error.localizedDescription
        case .missingDependencies:
            return "PlaylistBuilder dependencies were not provided."
        }
    }
}

public struct PlaylistBuilderDependencies: Sendable {
    public var profileProvider: SpotifyProfileProviding
    public var artistProvider: SpotifyArtistProviding
    public var trackProvider: SpotifyTrackProviding
    public var playlistEditor: SpotifyPlaylistEditing?

    public init(
        profileProvider: SpotifyProfileProviding,
        artistProvider: SpotifyArtistProviding,
        trackProvider: SpotifyTrackProviding,
        playlistEditor: SpotifyPlaylistEditing? = nil
    ) {
        self.profileProvider = profileProvider
        self.artistProvider = artistProvider
        self.trackProvider = trackProvider
        self.playlistEditor = playlistEditor
    }
}

public struct PlaylistResult: Sendable {
    public let playlistID: String?
    public let playlistName: String
    public let preparedTrackURIs: [String]
    public let addedTrackURIs: [String]
    public let displayTracks: [String]
    public let dryRun: Bool
    public let reusedExisting: Bool
    public let stats: PlaylistStats
}

public protocol SpotifyProfileProviding: Sendable {
    func currentUser() async throws -> SpotifyUserProfile
}

public protocol SpotifyArtistProviding: Sendable {
    func searchArtists(_ query: String, limit: Int) async throws -> [SpotifyArtist]
    func artist(byID id: String) async throws -> SpotifyArtist
    func topArtists(limit: Int) async throws -> [SpotifyArtist]
    func followedArtists(limit: Int) async throws -> [SpotifyArtist]
}

public protocol SpotifyTrackProviding: Sendable {
    func topTracks(for artistID: String, limit: Int) async throws -> [SpotifyTrack]
}

public protocol SpotifyPlaylistEditing: Sendable {
    func createPlaylist(
        userID: String,
        name: String,
        description: String,
        isPublic: Bool
    ) async throws -> String
}

public struct SpotifyUserProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let email: String?
}

public struct SpotifyArtist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct SpotifyTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let artists: [SpotifyArtist]
}

public struct PlaylistBuilderContext: Sendable {
    public var options: PlaylistOptions
    public var timestamp: Date

    public init(options: PlaylistOptions, timestamp: Date = .now) {
        self.options = options
        self.timestamp = timestamp
    }
}

public actor PlaylistBuilder {
    private let defaultDependencies: PlaylistBuilderDependencies?

    public init(dependencies: PlaylistBuilderDependencies? = nil) {
        self.defaultDependencies = dependencies
    }

    public func build(
        with context: PlaylistBuilderContext,
        dependencies overrideDependencies: PlaylistBuilderDependencies? = nil
    ) async throws -> PlaylistResult {
        let dependencies = try resolveDependencies(overrideDependencies)
        let options = context.options
        let resolvedPlaylistName = Self.makePlaylistName(
            baseName: options.playlistName,
            dateStamp: options.dateStamp,
            timestamp: context.timestamp
        )

        let manualQueries = Self.normalizedManualQueries(options.manualArtistQueries)
        var resolvedArtists: [SpotifyArtist] = []

        if !manualQueries.isEmpty {
            let manualArtists = try await resolveManualArtists(
                manualQueries,
                maxArtists: options.maxArtists,
                artistProvider: dependencies.artistProvider
            )
            resolvedArtists.append(contentsOf: manualArtists)
        }

        resolvedArtists = Array(resolvedArtists.prefix(options.maxArtists))

        guard !resolvedArtists.isEmpty else {
            throw PlaylistBuilderError.noArtistsResolved
        }

        let trackResolution = try await resolveTracks(
            for: resolvedArtists,
            options: options,
            trackProvider: dependencies.trackProvider
        )

        guard !trackResolution.tracks.isEmpty else {
            throw PlaylistBuilderError.noTracksResolved
        }

        let dedupeResult = Self.dedupeTracks(
            trackResolution.tracks,
            allowDeduplication: options.dedupeVariants
        )

        let truncatedTracks = Array(dedupeResult.uniqueTracks.prefix(options.maxTracks))
        let shuffledTracks = Self.applyShuffleIfNeeded(
            truncatedTracks,
            shuffle: options.shuffle,
            seed: options.shuffleSeed,
            fallbackSeed: UInt64(context.timestamp.timeIntervalSince1970)
        )

        let preparedURIs = shuffledTracks.map { "spotify:track:\($0.id)" }
        let displayTracks = shuffledTracks.map { Self.displayString(for: $0) }
        let totalUploaded = options.dryRun ? 0 : preparedURIs.count

        let stats = PlaylistStats(
            playlistName: resolvedPlaylistName,
            artistsRetrieved: resolvedArtists.count,
            topTracksRetrieved: trackResolution.topTracksRetrieved,
            variantsDeduped: dedupeResult.dedupedCount,
            totalPrepared: preparedURIs.count,
            totalUploaded: totalUploaded
        )

        return PlaylistResult(
            playlistID: nil,
            playlistName: resolvedPlaylistName,
            preparedTrackURIs: preparedURIs,
            addedTrackURIs: preparedURIs,
            displayTracks: displayTracks,
            dryRun: options.dryRun,
            reusedExisting: false,
            stats: stats
        )
    }

    private func resolveDependencies(_ override: PlaylistBuilderDependencies?) throws -> PlaylistBuilderDependencies {
        if let override {
            return override
        }
        if let defaultDependencies {
            return defaultDependencies
        }
        throw PlaylistBuilderError.missingDependencies
    }
}

// MARK: - Helpers

private extension PlaylistBuilder {
    static func makePlaylistName(baseName: String, dateStamp: Bool, timestamp: Date) -> String {
        guard dateStamp else { return baseName }
        return "\(baseName) \(Self.dateFormatter.string(from: timestamp))"
    }

    static func normalizedManualQueries(_ queries: [String]) -> [String] {
        queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func resolveManualArtists(
        _ queries: [String],
        maxArtists: Int,
        artistProvider: SpotifyArtistProviding
    ) async throws -> [SpotifyArtist] {
        var resolved: [SpotifyArtist] = []
        for query in queries {
            let results = try await artistProvider.searchArtists(query, limit: 1)
            if let artist = results.first {
                resolved.append(artist)
            }
            if resolved.count >= maxArtists {
                break
            }
        }
        return resolved
    }

    func resolveTracks(
        for artists: [SpotifyArtist],
        options: PlaylistOptions,
        trackProvider: SpotifyTrackProviding
    ) async throws -> (tracks: [SpotifyTrack], topTracksRetrieved: Int) {
        var prepared: [SpotifyTrack] = []
        var totalFetched = 0

        for artist in artists {
            let tracks = try await trackProvider.topTracks(for: artist.id, limit: options.limitPerArtist)
            let trimmed = Array(tracks.prefix(options.limitPerArtist))
            totalFetched += trimmed.count
            prepared.append(contentsOf: trimmed)
            if prepared.count >= options.maxTracks {
                break
            }
        }

        return (prepared, totalFetched)
    }

    static func dedupeTracks(_ tracks: [SpotifyTrack], allowDeduplication: Bool) -> (uniqueTracks: [SpotifyTrack], dedupedCount: Int) {
        guard allowDeduplication else {
            return (tracks, 0)
        }

        var seen = Set<String>()
        var unique: [SpotifyTrack] = []
        for track in tracks {
            if seen.insert(track.id).inserted {
                unique.append(track)
            }
        }
        let dedupedCount = tracks.count - unique.count
        return (unique, dedupedCount)
    }

    static func applyShuffleIfNeeded(
        _ tracks: [SpotifyTrack],
        shuffle: Bool,
        seed: Int?,
        fallbackSeed: UInt64
    ) -> [SpotifyTrack] {
        guard shuffle else { return tracks }
        let resolvedSeed: UInt64
        if let seed {
            resolvedSeed = UInt64(bitPattern: Int64(seed))
        } else {
            resolvedSeed = fallbackSeed == 0 ? 0xABCDEF : fallbackSeed
        }
        var generator = SeededRandomNumberGenerator(seed: resolvedSeed)
        return tracks.shuffled(using: &generator)
    }

    static func displayString(for track: SpotifyTrack) -> String {
        let artistNames = track.artists.map { $0.name }.joined(separator: ", ")
        return "\(artistNames) – \(track.name)"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed != 0 ? seed : 0xDEADBEEF
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}
