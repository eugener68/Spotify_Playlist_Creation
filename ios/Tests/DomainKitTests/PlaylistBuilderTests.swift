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
            shuffle: true,
            shuffleSeed: 1234,
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
                    "metallica": [SpotifyArtist(id: "metallica", name: "Metallica")],
                    "a-ha": [SpotifyArtist(id: "aha", name: "A-ha")]
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
        XCTAssertEqual(result.finalUploadURIs, result.preparedTrackURIs)
    }

    func testFixtureBReuseExistingWithShuffle() async throws {
        let options = PlaylistOptions(
            playlistName: "Morning Mix",
            dateStamp: false,
            limitPerArtist: 2,
            maxArtists: 3,
            maxTracks: 5,
            shuffle: true,
            shuffleSeed: 1234,
            dedupeVariants: true,
            reuseExisting: true,
            truncate: false,
            verbose: false,
            dryRun: false,
            manualArtistQueries: ["Adele", "Coldplay", "Muse"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        let trackProvider = MockTrackProvider(
            tracksByArtistID: [
                "adele": [
                    SpotifyTrack(id: "n1", name: "Hello", artists: [SpotifyArtist(id: "adele", name: "Adele")]),
                    SpotifyTrack(id: "n2", name: "Skyfall", artists: [SpotifyArtist(id: "adele", name: "Adele")])
                ],
                "coldplay": [
                    SpotifyTrack(id: "n3", name: "Fix You", artists: [SpotifyArtist(id: "coldplay", name: "Coldplay")]),
                    SpotifyTrack(id: "n4", name: "Paradise", artists: [SpotifyArtist(id: "coldplay", name: "Coldplay")])
                ],
                "muse": [
                    SpotifyTrack(id: "n5", name: "Uprising", artists: [SpotifyArtist(id: "muse", name: "Muse")])
                ]
            ]
        )

        let playlistEditor = MockPlaylistEditor(
            existingPlaylist: SpotifyPlaylistSummary(id: "old123", name: "Morning Mix", ownerID: "user123", trackCount: 3),
            existingTracks: [
                "spotify:track:t1",
                "spotify:track:n3",
                "spotify:track:t2"
            ]
        )

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(
                artistsByQuery: [
                    "adele": [SpotifyArtist(id: "adele", name: "Adele")],
                    "coldplay": [SpotifyArtist(id: "coldplay", name: "Coldplay")],
                    "muse": [SpotifyArtist(id: "muse", name: "Muse")]
                ]
            ),
            trackProvider: trackProvider,
            playlistEditor: playlistEditor
        )

        let context = PlaylistBuilderContext(options: options, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertTrue(result.reusedExisting)
        XCTAssertEqual(result.playlistID, "old123")
        let expectedPrepared: Set<String> = [
            "spotify:track:n1",
            "spotify:track:n2",
            "spotify:track:n3",
            "spotify:track:n4",
            "spotify:track:n5"
        ]
        XCTAssertEqual(Set(result.preparedTrackURIs), expectedPrepared)
        let expectedAdded = expectedPrepared.subtracting(["spotify:track:n3"])
        XCTAssertEqual(result.addedTrackURIs.count, expectedAdded.count)
        XCTAssertEqual(Set(result.addedTrackURIs), expectedAdded)
        XCTAssertEqual(result.stats.playlistName, "Morning Mix")
        XCTAssertEqual(result.stats.artistsRetrieved, 3)
        XCTAssertEqual(result.stats.topTracksRetrieved, 5)
        XCTAssertEqual(result.stats.variantsDeduped, 0)
        XCTAssertEqual(result.stats.totalPrepared, 5)
        XCTAssertEqual(result.stats.totalUploaded, result.addedTrackURIs.count)
        XCTAssertEqual(playlistEditor.replacedPayloads.count, 1)
        if let uploaded = playlistEditor.replacedPayloads.first?.uris {
            let preparedSet = Set(result.preparedTrackURIs)
            let expectedRemaining = playlistEditor.existingTracks.filter { !preparedSet.contains($0) }
            XCTAssertEqual(uploaded.count, result.preparedTrackURIs.count + expectedRemaining.count)
            XCTAssertEqual(Set(uploaded), Set(result.preparedTrackURIs + expectedRemaining))
            XCTAssertEqual(result.finalUploadURIs, uploaded)
        } else {
            XCTFail("Expected replacePlaylistTracks to be invoked")
        }
    }

    func testFixtureCTruncateExistingPlaylist() async throws {
        let options = PlaylistOptions(
            playlistName: "Mega Mix",
            dateStamp: false,
            limitPerArtist: 10,
            maxArtists: 10,
            maxTracks: 25,
            shuffle: false,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: true,
            truncate: true,
            verbose: false,
            dryRun: false,
            manualArtistQueries: ["Artist A", "Artist B", "Artist C"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        var tracksByArtist: [String: [SpotifyTrack]] = [:]
        for (index, artist) in ["a", "b", "c"].enumerated() {
            let artistID = "artist-\(artist)"
            let artistName = "Artist \(String(UnicodeScalar(65 + index)!))"
            tracksByArtist[artistID] = (1 ... 20).map { idx in
                SpotifyTrack(
                    id: "\(artist)-\(idx)",
                    name: "Song \(idx)",
                    artists: [SpotifyArtist(id: artistID, name: artistName)]
                )
            }
        }

        let trackProvider = MockTrackProvider(tracksByArtistID: tracksByArtist)
        let playlistEditor = MockPlaylistEditor(
            existingPlaylist: SpotifyPlaylistSummary(id: "truncate123", name: "Mega Mix", ownerID: "user123", trackCount: 100),
            existingTracks: (1 ... 50).map { "spotify:track:old\($0)" }
        )

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(
                artistsByQuery: [
                    "artist a": [SpotifyArtist(id: "artist-a", name: "Artist A")],
                    "artist b": [SpotifyArtist(id: "artist-b", name: "Artist B")],
                    "artist c": [SpotifyArtist(id: "artist-c", name: "Artist C")]
                ]
            ),
            trackProvider: trackProvider,
            playlistEditor: playlistEditor
        )

        let context = PlaylistBuilderContext(options: options, timestamp: Date(timeIntervalSince1970: 1_700_100_000))
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertTrue(result.reusedExisting)
        XCTAssertEqual(result.preparedTrackURIs.count, 25)
        XCTAssertEqual(result.addedTrackURIs, result.preparedTrackURIs)
        XCTAssertEqual(result.stats.playlistName, "Mega Mix")
        XCTAssertEqual(result.stats.artistsRetrieved, 3)
        XCTAssertEqual(result.stats.topTracksRetrieved, 30)
        XCTAssertEqual(result.stats.variantsDeduped, 0)
        XCTAssertEqual(result.stats.totalPrepared, 25)
        XCTAssertEqual(result.stats.totalUploaded, 25)
        XCTAssertEqual(playlistEditor.replacedPayloads.first?.uris, result.preparedTrackURIs)
        XCTAssertEqual(result.finalUploadURIs, result.preparedTrackURIs)
    }

    func testManualArtistResolutionPrefersExactMatches() async throws {
        let options = PlaylistOptions(
            playlistName: "Manual Test",
            dateStamp: false,
            limitPerArtist: 1,
            maxArtists: 1,
            maxTracks: 1,
            shuffle: false,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: false,
            truncate: false,
            verbose: false,
            dryRun: true,
            manualArtistQueries: ["Adele"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        let exactAdele = SpotifyArtist(id: "adele", name: "Adele")
        let lookalike = SpotifyArtist(id: "adele-castillon", name: "Adèle Castillon")
        let advancedQuery = #"artist:"adele""#.lowercased()

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(
                artistsByQuery: [
                    advancedQuery: [lookalike, exactAdele],
                    "adele": [SpotifyArtist(id: "acdc", name: "AC/DC")]
                ]
            ),
            trackProvider: MockTrackProvider(
                tracksByArtistID: [
                    "adele": [SpotifyTrack(id: "adele-track", name: "Hello", artists: [exactAdele])]
                ]
            )
        )

        let context = PlaylistBuilderContext(options: options, timestamp: Date(timeIntervalSince1970: 1_700_200_000))
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertEqual(result.preparedTrackURIs, ["spotify:track:adele-track"])
        XCTAssertEqual(result.displayTracks, ["Adele – Hello"])
    }

    func testPreferOriginalTracksFiltersVariants() async throws {
        let options = PlaylistOptions(
            playlistName: "Variants",
            dateStamp: false,
            limitPerArtist: 10,
            maxArtists: 5,
            maxTracks: 10,
            shuffle: false,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: false,
            truncate: false,
            verbose: false,
            dryRun: true,
            preferOriginalTracks: true,
            manualArtistQueries: ["Metallica"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        let metallica = SpotifyArtist(id: "metallica", name: "Metallica")
        let tracks: [SpotifyTrack] = [
            SpotifyTrack(id: "orig", name: "Nothing Else Matters", artists: [metallica]),
            SpotifyTrack(id: "remaster", name: "Nothing Else Matters - Remastered 2021", artists: [metallica]),
            SpotifyTrack(id: "live", name: "Nothing Else Matters (Live at Seattle)", artists: [metallica]),
            SpotifyTrack(id: "acoustic", name: "Nothing Else Matters - Acoustic", artists: [metallica])
        ]

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(artistsByQuery: [
                "metallica": [metallica]
            ]),
            trackProvider: MockTrackProvider(tracksByArtistID: [
                "metallica": tracks
            ])
        )

        let context = PlaylistBuilderContext(options: options, timestamp: Date(timeIntervalSince1970: 1_700_300_000))
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertEqual(result.preparedTrackURIs, ["spotify:track:orig"])
        XCTAssertEqual(result.stats.variantsDeduped, 3)
        XCTAssertEqual(result.displayTracks.first, "Metallica – Nothing Else Matters")
    }

    func testVariantFilteringCanBeDisabled() async throws {
        let options = PlaylistOptions(
            playlistName: "Variants",
            dateStamp: false,
            limitPerArtist: 10,
            maxArtists: 5,
            maxTracks: 10,
            shuffle: false,
            shuffleSeed: nil,
            dedupeVariants: true,
            reuseExisting: false,
            truncate: false,
            verbose: false,
            dryRun: true,
            preferOriginalTracks: false,
            manualArtistQueries: ["Metallica"],
            includeLibraryArtists: false,
            includeFollowedArtists: false
        )

        let metallica = SpotifyArtist(id: "metallica", name: "Metallica")
        let tracks: [SpotifyTrack] = [
            SpotifyTrack(id: "orig", name: "Nothing Else Matters", artists: [metallica]),
            SpotifyTrack(id: "remaster", name: "Nothing Else Matters - Remastered 2021", artists: [metallica]),
            SpotifyTrack(id: "live", name: "Nothing Else Matters (Live at Seattle)", artists: [metallica]),
            SpotifyTrack(id: "acoustic", name: "Nothing Else Matters - Acoustic", artists: [metallica])
        ]

        let builder = PlaylistBuilder()
        let dependencies = PlaylistBuilderDependencies(
            profileProvider: MockProfileProvider(userID: "user123"),
            artistProvider: MockArtistProvider(artistsByQuery: [
                "metallica": [metallica]
            ]),
            trackProvider: MockTrackProvider(tracksByArtistID: [
                "metallica": tracks
            ])
        )

        let context = PlaylistBuilderContext(options: options, timestamp: Date(timeIntervalSince1970: 1_700_300_001))
        let result = try await builder.build(with: context, dependencies: dependencies)

        XCTAssertEqual(result.preparedTrackURIs.count, 4)
        XCTAssertEqual(result.stats.variantsDeduped, 0)
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
    let artistsByQuery: [String: [SpotifyArtist]]

    func searchArtists(_ query: String, limit: Int) async throws -> [SpotifyArtist] {
        if let artists = artistsByQuery[query.lowercased()], !artists.isEmpty {
            return Array(artists.prefix(limit))
        }
        return []
    }

    func artist(byID id: String) async throws -> SpotifyArtist {
        for artists in artistsByQuery.values {
            if let match = artists.first(where: { $0.id.lowercased() == id.lowercased() }) {
                return match
            }
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

private final class MockPlaylistEditor: SpotifyPlaylistEditing {
    let existingPlaylist: SpotifyPlaylistSummary?
    let existingTracks: [String]
    private(set) var replacedPayloads: [(playlistID: String, uris: [String])] = []
    private(set) var createdPlaylists: [(userID: String, name: String, description: String, isPublic: Bool)] = []

    init(existingPlaylist: SpotifyPlaylistSummary?, existingTracks: [String]) {
        self.existingPlaylist = existingPlaylist
        self.existingTracks = existingTracks
    }

    func createPlaylist(
        userID: String,
        name: String,
        description: String,
        isPublic: Bool
    ) async throws -> String {
        createdPlaylists.append((userID, name, description, isPublic))
        return "created-\(name)"
    }

    func findPlaylist(named name: String, ownerID: String) async throws -> SpotifyPlaylistSummary? {
        guard let playlist = existingPlaylist, playlist.ownerID == ownerID, playlist.name == name else {
            return nil
        }
        return playlist
    }

    func playlistTracks(playlistID: String) async throws -> [String] {
        guard existingPlaylist?.id == playlistID else {
            return []
        }
        return existingTracks
    }

    func replacePlaylistTracks(playlistID: String, uris: [String]) async throws {
        replacedPayloads.append((playlistID, uris))
    }
}

extension MockPlaylistEditor: @unchecked Sendable {}