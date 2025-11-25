import Foundation

public struct PlaylistOptions: Codable, Equatable, Sendable {
    public var playlistName: String
    public var dateStamp: Bool
    public var limitPerArtist: Int
    public var maxArtists: Int
    public var maxTracks: Int
    public var shuffle: Bool
    public var shuffleSeed: Int?
    public var dedupeVariants: Bool
    public var reuseExisting: Bool
    public var truncate: Bool
    public var verbose: Bool
    public var dryRun: Bool
    public var preferOriginalTracks: Bool
    public var manualArtistQueries: [String]
    public var artistsFileBookmark: Data?
    public var includeLibraryArtists: Bool
    public var includeFollowedArtists: Bool

    public init(
        playlistName: String = "Untitled Playlist",
        dateStamp: Bool = true,
        limitPerArtist: Int = 5,
        maxArtists: Int = 25,
        maxTracks: Int = 100,
        shuffle: Bool = false,
        shuffleSeed: Int? = nil,
        dedupeVariants: Bool = true,
        reuseExisting: Bool = true,
        truncate: Bool = false,
        verbose: Bool = false,
        dryRun: Bool = false,
        preferOriginalTracks: Bool = true,
        manualArtistQueries: [String] = [],
        artistsFileBookmark: Data? = nil,
        includeLibraryArtists: Bool = true,
        includeFollowedArtists: Bool = false
    ) {
        self.playlistName = playlistName
        self.dateStamp = dateStamp
        self.limitPerArtist = limitPerArtist
        self.maxArtists = maxArtists
        self.maxTracks = maxTracks
        self.shuffle = shuffle
        self.shuffleSeed = shuffleSeed
        self.dedupeVariants = dedupeVariants
        self.reuseExisting = reuseExisting
        self.truncate = truncate
        self.verbose = verbose
        self.dryRun = dryRun
        self.preferOriginalTracks = preferOriginalTracks
        self.manualArtistQueries = manualArtistQueries
        self.artistsFileBookmark = artistsFileBookmark
        self.includeLibraryArtists = includeLibraryArtists
        self.includeFollowedArtists = includeFollowedArtists
    }
}
