import Foundation

public struct SpotifyPlaylistSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ownerID: String
    public let trackCount: Int

    public init(id: String, name: String, ownerID: String, trackCount: Int) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.trackCount = trackCount
    }
}
