import Foundation
import DomainKit
import SpotifyAPIKit

public extension AppDependencies {
    static func demo() -> AppDependencies {
        let profile = DemoProfileProvider(userID: "demo-user")
        let artists = DemoArtistProvider(
            artistsByQuery: [
                "metallica": SpotifyArtist(id: "metallica", name: "Metallica"),
                "a-ha": SpotifyArtist(id: "aha", name: "A-ha"),
                "aha": SpotifyArtist(id: "aha", name: "A-ha"),
                "adele": SpotifyArtist(id: "adele", name: "Adele")
            ]
        )
        let tracks = DemoTrackProvider(
            tracksByArtistID: [
                "metallica": [
                    SpotifyTrack(id: "m1", name: "Master of Puppets", artists: [SpotifyArtist(id: "metallica", name: "Metallica")]),
                    SpotifyTrack(id: "m2", name: "Nothing Else Matters", artists: [SpotifyArtist(id: "metallica", name: "Metallica")]),
                    SpotifyTrack(id: "m3", name: "Enter Sandman", artists: [SpotifyArtist(id: "metallica", name: "Metallica")])
                ],
                "aha": [
                    SpotifyTrack(id: "aha1", name: "Take On Me", artists: [SpotifyArtist(id: "aha", name: "A-ha")]),
                    SpotifyTrack(id: "aha2", name: "Sun Always Shines", artists: [SpotifyArtist(id: "aha", name: "A-ha")]),
                    SpotifyTrack(id: "aha3", name: "Cry Wolf", artists: [SpotifyArtist(id: "aha", name: "A-ha")])
                ],
                "adele": [
                    SpotifyTrack(id: "n1", name: "Hello", artists: [SpotifyArtist(id: "adele", name: "Adele")]),
                    SpotifyTrack(id: "n2", name: "Skyfall", artists: [SpotifyArtist(id: "adele", name: "Adele")])
                ]
            ]
        )
        let playlistEditor = DemoPlaylistEditor()
        let builderDependencies = PlaylistBuilderDependencies(
            profileProvider: profile,
            artistProvider: artists,
            trackProvider: tracks,
            playlistEditor: playlistEditor
        )
        let builder = PlaylistBuilder(dependencies: builderDependencies)

        let dummyConfiguration = SpotifyAPIConfiguration(
            clientID: "demo",
            redirectURI: URL(string: "autoplaylistbuilder-demo://callback")!,
            scopes: []
        )
        let apiClient = SpotifyAPIClient(
            configuration: dummyConfiguration,
            tokenProvider: InMemoryAccessTokenProvider(initialToken: "demo-token")
        )
        return AppDependencies(playlistBuilder: builder, apiClient: apiClient)
    }
}

private struct DemoProfileProvider: SpotifyProfileProviding {
    let userID: String

    func currentUser() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: userID, displayName: "Demo User", email: "demo@example.com")
    }
}

private struct DemoArtistProvider: SpotifyArtistProviding {
    let artistsByQuery: [String: SpotifyArtist]

    func searchArtists(_ query: String, limit: Int) async throws -> [SpotifyArtist] {
        if let artist = artistsByQuery[query.lowercased()] {
            return [artist]
        }
        return []
    }

    func artist(byID id: String) async throws -> SpotifyArtist {
        if let match = artistsByQuery.values.first(where: { $0.id == id }) {
            return match
        }
        throw PlaylistBuilderError.noArtistsResolved
    }

    func topArtists(limit: Int) async throws -> [SpotifyArtist] {
        []
    }

    func followedArtists(limit: Int) async throws -> [SpotifyArtist] {
        []
    }
}

private struct DemoTrackProvider: SpotifyTrackProviding {
    let tracksByArtistID: [String: [SpotifyTrack]]

    func topTracks(for artistID: String, limit: Int) async throws -> [SpotifyTrack] {
        tracksByArtistID[artistID] ?? []
    }
}

private actor DemoPlaylistEditor: SpotifyPlaylistEditing {
    private let summary = SpotifyPlaylistSummary(
        id: "demo-playlist",
        name: "Road Trip Mix",
        ownerID: "demo-user",
        trackCount: 3
    )
    private var storedTracks: [String] = [
        "spotify:track:t1",
        "spotify:track:t2",
        "spotify:track:aha1"
    ]

    func createPlaylist(
        userID: String,
        name: String,
        description: String,
        isPublic: Bool
    ) async throws -> String {
        summary.id
    }

    func findPlaylist(named name: String, ownerID: String) async throws -> SpotifyPlaylistSummary? {
        guard name.caseInsensitiveCompare(summary.name) == .orderedSame, ownerID == summary.ownerID else {
            return nil
        }
        return summary
    }

    func playlistTracks(playlistID: String) async throws -> [String] {
        guard playlistID == summary.id else { return [] }
        return storedTracks
    }

    func replacePlaylistTracks(playlistID: String, uris: [String]) async throws {
        guard playlistID == summary.id else { return }
        storedTracks = uris
    }
}

struct DemoArtistSuggestionProvider: ArtistSuggestionProviding {
    private let catalog: [ArtistSummary] = [
        ArtistSummary(id: "metallica", name: "Metallica", followers: 21000000, genres: ["metal"], imageURL: nil),
        ArtistSummary(id: "aha", name: "A-ha", followers: 3500000, genres: ["synthpop"], imageURL: nil),
        ArtistSummary(id: "adele", name: "Adele", followers: 32000000, genres: ["pop"], imageURL: nil)
    ]

    func searchArtistSummaries(_ query: String, limit: Int) async throws -> [ArtistSummary] {
        guard !query.isEmpty else { return [] }
        let lowercased = query.lowercased()
        return catalog
            .filter { $0.name.lowercased().contains(lowercased) }
            .prefix(limit)
            .map { $0 }
    }
}
