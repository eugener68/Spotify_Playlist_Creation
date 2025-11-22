import XCTest
@testable import DomainKit

final class PlaylistBuilderTests: XCTestCase {
    func testFixtureAManualArtistsDryRun() async throws {
        let options = PlaylistOptions(
            playlistName: "Road Trip Mix",
            dateStamp: true,
            limitPerArtist: 3,
            maxArtists: 10,
            maxTracks: 20,
            shuffle: false,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: false,
            truncate: false,
            verbose: false,
            dryRun: true,
            manualArtistQueries: ["Metallica", "A-ha"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        let timestamp = ISO8601DateFormatter().date(from: "2025-11-20T12:00:00Z") ?? Date()

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(
                artistsByQuery: [
                    "metallica": SpotifyArtist(id: "metallica", name: "Metallica"),
                    "a-ha": SpotifyArtist(id: "aha", name: "A-ha")
                ]
            ),
            trackProvider: MockTrackProvider(
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
                    ]
                ]
            )
        )

        let context = PlaylistBuilderContext(options: options, timestamp: timestamp)
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertEqual(result.playlistName, "Road Trip Mix 2025-11-20")
        XCTAssertEqual(result.preparedTrackURIs, [
            "spotify:track:m1",
            "spotify:track:m2",
            "spotify:track:m3",
            "spotify:track:aha1",
            "spotify:track:aha2",
            "spotify:track:aha3"
        ])
        XCTAssertEqual(result.addedTrackURIs, result.preparedTrackURIs)
        XCTAssertEqual(result.stats.totalPrepared, 6)
        XCTAssertEqual(result.stats.artistsRetrieved, 2)
        XCTAssertEqual(result.stats.topTracksRetrieved, 6)
        XCTAssertEqual(result.stats.totalUploaded, 0)
        XCTAssertEqual(result.displayTracks.first, "Metallica – Master of Puppets")
        XCTAssertEqual(result.displayTracks.last, "A-ha – Cry Wolf")
    }
}

// MARK: - Test Doubles

private struct MockProfileProvider: SpotifyProfileProviding {
    let userID: String

    func currentUser() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: userID, displayName: "Tester", email: "tester@example.com")
    }
}

private struct MockArtistProvider: SpotifyArtistProviding {
    let artistsByQuery: [String: SpotifyArtist]

    func searchArtists(_ query: String, limit: Int) async throws -> [SpotifyArtist] {
        if let artist = artistsByQuery[query.lowercased()] {
            return [artist]
        }
        return []
    }

    func artist(byID id: String) async throws -> SpotifyArtist {
        if let match = artistsByQuery.values.first(where: { $0.id.lowercased() == id.lowercased() }) {
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

private struct MockTrackProvider: SpotifyTrackProviding {
    let tracksByArtistID: [String: [SpotifyTrack]]

    func topTracks(for artistID: String, limit: Int) async throws -> [SpotifyTrack] {
        tracksByArtistID[artistID] ?? []
    }
}