import Foundation

public struct PlaylistStats: Codable, Equatable, Sendable {
    public let playlistName: String
    public let artistsRetrieved: Int
    public let topTracksRetrieved: Int
    public let variantsDeduped: Int
    public let totalPrepared: Int
    public let totalUploaded: Int

    public init(
        playlistName: String,
        artistsRetrieved: Int,
        topTracksRetrieved: Int,
        variantsDeduped: Int,
        totalPrepared: Int,
        totalUploaded: Int
    ) {
        self.playlistName = playlistName
        self.artistsRetrieved = artistsRetrieved
        self.topTracksRetrieved = topTracksRetrieved
        self.variantsDeduped = variantsDeduped
        self.totalPrepared = totalPrepared
        self.totalUploaded = totalUploaded
    }

    public func lines() -> [String] {
        [
            "Playlist name: \(playlistName)",
            "Artists retrieved: \(artistsRetrieved)",
            "Top songs retrieved: \(topTracksRetrieved)",
            "Variants deduped: \(variantsDeduped)",
            "Total tracks added to the list: \(totalUploaded)"
        ]
    }
}
