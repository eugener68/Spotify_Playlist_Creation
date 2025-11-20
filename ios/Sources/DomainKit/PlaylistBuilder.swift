import Foundation

public enum PlaylistBuilderError: Error, LocalizedError {
    case missingUserID
    case noArtistsResolved
    case noTracksResolved
    case artistsFileMissing(String)
    case underlying(Error)

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
        }
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
    public init() {}

    public func build(with context: PlaylistBuilderContext) async throws -> PlaylistResult {
        // Placeholder implementation; real logic will mirror core/playlist_builder.py.
        let stats = PlaylistStats(
            playlistName: context.options.playlistName,
            artistsRetrieved: 0,
            topTracksRetrieved: 0,
            variantsDeduped: 0,
            totalPrepared: 0,
            totalUploaded: 0
        )

        return PlaylistResult(
            playlistID: nil,
            playlistName: context.options.playlistName,
            preparedTrackURIs: [],
            addedTrackURIs: [],
            displayTracks: [],
            dryRun: context.options.dryRun,
            reusedExisting: false,
            stats: stats
        )
    }
}
