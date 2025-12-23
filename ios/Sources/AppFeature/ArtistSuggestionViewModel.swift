import Combine
import Foundation
import SpotifyAPIKit

@MainActor
final class ArtistSuggestionViewModel: ObservableObject {
    struct Suggestion: Identifiable, Equatable {
        let id: String
        let name: String
        let subtitle: String?
        let imageURL: URL?
    }

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var isLoading = false

    private let provider: ArtistSuggestionProviding
    private var lookupTask: Task<Void, Never>?
    private let limit: Int

    init(provider: ArtistSuggestionProviding, limit: Int = 6) {
        self.provider = provider
        self.limit = limit
    }

    deinit {
        lookupTask?.cancel()
    }

    func updateQuery(_ query: String) {
        lookupTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            isLoading = false
            return
        }
        lookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                await self.performSearch(query: trimmed)
            } catch is CancellationError {
                // Swallow cancellation to allow the latest query to run.
            } catch {
                self.suggestions = []
                self.isLoading = false
            }
        }
    }

    func clear() {
        lookupTask?.cancel()
        suggestions = []
        isLoading = false
    }

    private func performSearch(query: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await provider.searchArtistSummaries(query, limit: limit)
            suggestions = results.map { summary in
                Suggestion(
                    id: summary.id,
                    name: summary.name,
                    subtitle: subtitle(from: summary),
                    imageURL: summary.imageURL
                )
            }
        } catch is CancellationError {
            // Ignore cancellation, a new lookup has been scheduled.
        } catch {
            suggestions = []
        }
    }

    private func subtitle(from summary: ArtistSummary) -> String? {
        var parts: [String] = []
        if let followersString = formattedFollowers(summary.followers) {
            parts.append(L10n.ArtistInput.suggestionFollowers(followersString))
        }
        if let genre = summary.genres.first, !genre.isEmpty {
            parts.append(genre.capitalized)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func formattedFollowers(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return Self.followersFormatter.string(from: NSNumber(value: count))
    }

    private static let followersFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()
}
