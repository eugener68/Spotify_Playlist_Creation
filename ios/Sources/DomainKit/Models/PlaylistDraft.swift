import Foundation

public struct TrackDescriptor: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let artistNames: [String]
    public let albumTitle: String?
    public let durationMs: Int?
    public let isrc: String?

    // Provider-specific identifiers (optional).
    public let appleMusicSongID: String?
    public let spotifyTrackURI: String?

    public init(
        title: String,
        artistNames: [String],
        albumTitle: String? = nil,
        durationMs: Int? = nil,
        isrc: String? = nil,
        appleMusicSongID: String? = nil,
        spotifyTrackURI: String? = nil
    ) {
        self.title = title
        self.artistNames = artistNames
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.isrc = isrc
        self.appleMusicSongID = appleMusicSongID
        self.spotifyTrackURI = spotifyTrackURI
    }

    public var displayString: String {
        let artists = artistNames.joined(separator: ", ")
        return artists.isEmpty ? title : "\(artists) — \(title)"
    }
}

public struct PlaylistDraft: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let tracks: [TrackDescriptor]

    public init(name: String, description: String? = nil, tracks: [TrackDescriptor]) {
        self.name = name
        self.description = description
        self.tracks = tracks
    }
}
