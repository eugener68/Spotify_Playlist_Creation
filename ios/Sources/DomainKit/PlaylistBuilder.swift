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

public struct PlaylistResult: Equatable, Sendable {
    public let playlistID: String?
    public let playlistName: String
    public let preparedTrackURIs: [String]
    public let addedTrackURIs: [String]
    public let finalUploadURIs: [String]
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
    func findPlaylist(named name: String, ownerID: String) async throws -> SpotifyPlaylistSummary?
    func playlistTracks(playlistID: String) async throws -> [String]
    func replacePlaylistTracks(playlistID: String, uris: [String]) async throws
}

public struct SpotifyUserProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let email: String?

    public init(id: String, displayName: String?, email: String?) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }
}

public struct SpotifyArtist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SpotifyTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let artists: [SpotifyArtist]

    public init(id: String, name: String, artists: [SpotifyArtist]) {
        self.id = id
        self.name = name
        self.artists = artists
    }
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

        let variantFilterResult: VariantFilterResult
        if options.preferOriginalTracks {
            variantFilterResult = Self.removeVariantVersions(from: dedupeResult.uniqueTracks)
        } else {
            variantFilterResult = VariantFilterResult(tracks: dedupeResult.uniqueTracks, removedCount: 0)
        }

        let truncatedTracks = Array(variantFilterResult.tracks.prefix(options.maxTracks))
        let fallbackSeed = Self.shuffleSeed(from: context.timestamp)
        let shuffledTracks = Self.applyShuffleIfNeeded(
            truncatedTracks,
            shuffle: options.shuffle,
            seed: options.shuffleSeed,
            fallbackSeed: fallbackSeed
        )

        let preparedURIs = shuffledTracks.map { "spotify:track:\($0.id)" }
        let displayTracks = shuffledTracks.map { Self.displayString(for: $0) }
        var playlistID: String?
        var addedTrackURIs = preparedURIs
        var reusedExisting = false
        var uploadURIs = preparedURIs
        var totalUploaded = options.dryRun ? 0 : preparedURIs.count

        if options.reuseExisting {
            guard let playlistEditor = dependencies.playlistEditor else {
                throw PlaylistBuilderError.missingDependencies
            }
            let profile = try await dependencies.profileProvider.currentUser()
            guard !profile.id.isEmpty else {
                throw PlaylistBuilderError.missingUserID
            }

            if let existing = try await playlistEditor.findPlaylist(named: resolvedPlaylistName, ownerID: profile.id) {
                reusedExisting = true
                playlistID = existing.id
                let existingURIs = try await playlistEditor.playlistTracks(playlistID: existing.id)
                let existingSet = Set(existingURIs)
                addedTrackURIs = preparedURIs.filter { !existingSet.contains($0) }

                if options.truncate {
                    uploadURIs = Array(preparedURIs.prefix(options.maxTracks))
                    totalUploaded = options.dryRun ? 0 : uploadURIs.count
                } else {
                    let remainingExisting = Self.remainingExistingTracks(existingURIs, excluding: preparedURIs)
                    uploadURIs = preparedURIs + remainingExisting
                    totalUploaded = options.dryRun ? 0 : addedTrackURIs.count
                }

                uploadURIs = Self.applyShuffleIfNeeded(
                    uploadURIs,
                    shuffle: options.shuffle,
                    seed: options.shuffleSeed,
                    fallbackSeed: fallbackSeed
                )

                if options.truncate {
                    uploadURIs = Array(uploadURIs.prefix(options.maxTracks))
                }

                if !options.dryRun {
                    try await playlistEditor.replacePlaylistTracks(playlistID: existing.id, uris: uploadURIs)
                }
            } else if !options.dryRun {
                playlistID = try await createPlaylist(
                    named: resolvedPlaylistName,
                    description: "AutoPlaylistBuilder",
                    profileProvider: dependencies.profileProvider,
                    playlistEditor: playlistEditor,
                    tracks: uploadURIs
                )
            }
        } else if !options.dryRun {
            guard let playlistEditor = dependencies.playlistEditor else {
                throw PlaylistBuilderError.missingDependencies
            }
            playlistID = try await createPlaylist(
                named: resolvedPlaylistName,
                description: "Spotify Playlist Builder",
                profileProvider: dependencies.profileProvider,
                playlistEditor: playlistEditor,
                tracks: uploadURIs
            )
        }

        let stats = PlaylistStats(
            playlistName: resolvedPlaylistName,
            artistsRetrieved: resolvedArtists.count,
            topTracksRetrieved: trackResolution.topTracksRetrieved,
            variantsDeduped: dedupeResult.dedupedCount + variantFilterResult.removedCount,
            totalPrepared: preparedURIs.count,
            totalUploaded: totalUploaded
        )

        return PlaylistResult(
            playlistID: playlistID,
            playlistName: resolvedPlaylistName,
            preparedTrackURIs: preparedURIs,
            addedTrackURIs: addedTrackURIs,
            finalUploadURIs: uploadURIs,
            displayTracks: displayTracks,
            dryRun: options.dryRun,
            reusedExisting: reusedExisting,
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

    static func shuffleSeed(from timestamp: Date) -> UInt64 {
        let microseconds = UInt64(timestamp.timeIntervalSince1970 * 1_000_000)
        return microseconds == 0 ? 0xABCDEF : microseconds
    }

    func resolveManualArtists(
        _ queries: [String],
        maxArtists: Int,
        artistProvider: SpotifyArtistProviding
    ) async throws -> [SpotifyArtist] {
        var resolved: [SpotifyArtist] = []
        for rawQuery in queries {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            let searchQueries = Self.artistSearchQueries(for: query)
            var matchedArtist: SpotifyArtist?
            for searchQuery in searchQueries {
                let results = try await artistProvider.searchArtists(searchQuery, limit: Self.manualArtistSearchLimit)
                if let bestMatch = Self.bestArtistMatch(for: query, in: results) {
                    matchedArtist = bestMatch
                    break
                }
            }
            if let matchedArtist {
                resolved.append(matchedArtist)
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

    static func removeVariantVersions(from tracks: [SpotifyTrack]) -> VariantFilterResult {
        guard !tracks.isEmpty else {
            return VariantFilterResult(tracks: tracks, removedCount: 0)
        }
        var bestByKey: [VariantKey: (track: SpotifyTrack, score: Int)] = [:]
        for track in tracks {
            let key = VariantKey(artists: canonicalArtistKey(for: track.artists), title: canonicalTrackTitle(for: track.name))
            let score = variantScore(for: track.name)
            if let current = bestByKey[key] {
                if score < current.score {
                    bestByKey[key] = (track, score)
                }
            } else {
                bestByKey[key] = (track, score)
            }
        }
        var keptKeys = Set<VariantKey>()
        var filtered: [SpotifyTrack] = []
        for track in tracks {
            let key = VariantKey(artists: canonicalArtistKey(for: track.artists), title: canonicalTrackTitle(for: track.name))
            guard let best = bestByKey[key] else { continue }
            if best.track.id == track.id && !keptKeys.contains(key) {
                filtered.append(track)
                keptKeys.insert(key)
            }
        }
        return VariantFilterResult(tracks: filtered, removedCount: tracks.count - filtered.count)
    }

    static func canonicalArtistKey(for artists: [SpotifyArtist]) -> String {
        artists
            .map { normalizeArtistName($0.name) }
            .joined(separator: ",")
    }

    static func canonicalTrackTitle(for title: String) -> String {
        var lowered = title.lowercased()
        lowered = stripVariantParentheticals(from: lowered)
        lowered = stripVariantSuffix(from: lowered)
        lowered = lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return lowered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func variantScore(for title: String) -> Int {
        let lower = title.lowercased()
        var score = 0
        for keyword in variantKeywords {
            if lower.contains(keyword) {
                score += 10
            }
        }
        if lower.contains("(") || lower.contains("[") {
            score += 1
        }
        if lower.contains(" - ") || lower.contains(" – ") || lower.contains(" — ") {
            score += 1
        }
        return score
    }

    static func stripVariantParentheticals(from text: String) -> String {
        var result = text
        var currentIndex = result.startIndex
        while currentIndex < result.endIndex {
            guard let openIndex = result[currentIndex...].firstIndex(where: { $0 == "(" || $0 == "[" }) else { break }
            let closingChar: Character = result[openIndex] == "(" ? ")" : "]"
            guard let closeIndex = result[openIndex...].firstIndex(of: closingChar) else { break }
            let content = result[result.index(after: openIndex)..<closeIndex]
            if containsVariantKeyword(in: String(content)) {
                result.removeSubrange(openIndex...closeIndex)
                currentIndex = result.startIndex
            } else {
                currentIndex = result.index(after: closeIndex)
            }
        }
        return result
    }

    static func stripVariantSuffix(from text: String) -> String {
        for delimiter in [" - ", " – ", " — ", ": "] {
            if let range = text.range(of: delimiter) {
                let suffix = text[range.upperBound...]
                if containsVariantKeyword(in: String(suffix)) {
                    return String(text[..<range.lowerBound])
                }
            }
        }
        return text
    }

    static func containsVariantKeyword(in text: String) -> Bool {
        let lower = text.lowercased()
        return variantKeywords.contains(where: { lower.contains($0) })
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
        return balancedShuffle(tracks, generator: &generator)
    }

    static func applyShuffleIfNeeded(
        _ uris: [String],
        shuffle: Bool,
        seed: Int?,
        fallbackSeed: UInt64
    ) -> [String] {
        guard shuffle else { return uris }
        let resolvedSeed: UInt64
        if let seed {
            resolvedSeed = UInt64(bitPattern: Int64(seed))
        } else {
            resolvedSeed = fallbackSeed == 0 ? 0xABCDEF : fallbackSeed
        }
        var generator = SeededRandomNumberGenerator(seed: resolvedSeed)
        return uris.shuffled(using: &generator)
    }

    static func displayString(for track: SpotifyTrack) -> String {
        let artistNames = track.artists.map { $0.name }.joined(separator: ", ")
        return "\(artistNames) – \(track.name)"
    }

    static func balancedShuffle<G: RandomNumberGenerator>(_ tracks: [SpotifyTrack], generator: inout G) -> [SpotifyTrack] {
        guard tracks.count > 2 else {
            return tracks.shuffled(using: &generator)
        }

        var buckets = Dictionary(grouping: tracks) { canonicalArtistKey(for: $0.artists) }
            .map { key, value in
                ArtistBucket(key: key, tracks: value.shuffled(using: &generator))
            }

        var ordered: [SpotifyTrack] = []
        var previousKey: String?

        while !buckets.isEmpty {
            // Prefer spreading artists by always selecting from the bucket with the most remaining tracks,
            // only repeating the previous artist when it is unavoidable.
            let ranked: [(index: Int, remaining: Int, tieBreak: UInt64)] = buckets.indices.map { index in
                (index: index, remaining: buckets[index].tracks.count, tieBreak: generator.next())
            }
            let sorted = ranked.sorted { a, b in
                if a.remaining != b.remaining { return a.remaining > b.remaining }
                return a.tieBreak < b.tieBreak
            }

            let bucketPosition = sorted.first(where: { buckets[$0.index].key != previousKey })?.index ?? sorted[0].index
            var bucket = buckets[bucketPosition]
            if let nextTrack = bucket.tracks.popLast() {
                ordered.append(nextTrack)
                previousKey = bucket.key
            }
            if bucket.tracks.isEmpty {
                buckets.remove(at: bucketPosition)
            } else {
                buckets[bucketPosition] = bucket
            }
        }

        return ordered
    }

    private static let manualArtistSearchLimit = 5
    private static let variantKeywords: [String] = [
        "remaster",
        "remix",
        "mix",
        "live",
        "acoustic",
        "karaoke",
        "instrumental",
        "edit",
        "version"
    ]

    static func artistSearchQueries(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let quoted = "\"\(trimmed)\""
        let advanced = "artist:\(quoted)"
        if trimmed.hasPrefix("artist:") {
            return [trimmed]
        }
        if advanced == trimmed {
            return [trimmed]
        }
        return [advanced, trimmed]
    }

    static func bestArtistMatch(for query: String, in candidates: [SpotifyArtist]) -> SpotifyArtist? {
        guard !candidates.isEmpty else { return nil }
        let normalizedQuery = normalizeArtistName(query)
        let normalizedCandidates = candidates.map { ($0, normalizeArtistName($0.name)) }
        if let exact = normalizedCandidates.first(where: { $0.1 == normalizedQuery }) {
            return exact.0
        }
        if let prefix = normalizedCandidates.first(where: { $0.1.hasPrefix(normalizedQuery + " ") }) {
            return prefix.0
        }
        if let contains = normalizedCandidates.first(where: { $0.1.contains(normalizedQuery) }) {
            return contains.0
        }
        return candidates.first
    }

    static func normalizeArtistName(_ name: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func remainingExistingTracks(_ existing: [String], excluding prepared: [String]) -> [String] {
        let preparedSet = Set(prepared)
        var seen = preparedSet
        var result: [String] = []
        for uri in existing {
            if seen.insert(uri).inserted {
                result.append(uri)
            }
        }
        return result
    }

    func createPlaylist(
        named name: String,
        description: String,
        profileProvider: SpotifyProfileProviding,
        playlistEditor: SpotifyPlaylistEditing,
        tracks: [String]
    ) async throws -> String {
        let profile = try await profileProvider.currentUser()
        guard !profile.id.isEmpty else {
            throw PlaylistBuilderError.missingUserID
        }
        let playlistID = try await playlistEditor.createPlaylist(
            userID: profile.id,
            name: name,
            description: description,
            isPublic: false
        )
        if !tracks.isEmpty {
            try await playlistEditor.replacePlaylistTracks(playlistID: playlistID, uris: tracks)
        }
        return playlistID
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

private struct VariantFilterResult {
    let tracks: [SpotifyTrack]
    let removedCount: Int
}

private struct VariantKey: Hashable {
    let artists: String
    let title: String
}

private struct ArtistBucket {
    let key: String
    var tracks: [SpotifyTrack]
}
