import Foundation
import SpotifyAPIKit

@MainActor
final class ArtistIdeasViewModel: ObservableObject {
    @Published var prompt: String = ""
    @Published private(set) var suggestions: [ArtistSuggestionViewModel.Suggestion] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let provider: ArtistIdeasProviding
    private let defaultArtistCount: Int
    private var task: Task<Void, Never>?

    init(provider: ArtistIdeasProviding, defaultArtistCount: Int = 20) {
        self.provider = provider
        self.defaultArtistCount = defaultArtistCount
    }

    deinit {
        task?.cancel()
    }

    func clear() {
        task?.cancel()
        isLoading = false
        errorMessage = nil
        suggestions = []
    }

    func generate(userId: String? = nil) {
        task?.cancel()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await provider.generateArtistIdeas(
                    prompt: trimmed,
                    artistCount: defaultArtistCount,
                    userId: userId
                )
                self.suggestions = results.map { summary in
                    ArtistSuggestionViewModel.Suggestion(
                        id: summary.id,
                        name: summary.name,
                        subtitle: self.subtitle(from: summary),
                        imageURL: summary.imageURL
                    )
                }
                self.isLoading = false
            } catch is CancellationError {
                // ignored
            } catch {
                self.suggestions = []
                self.isLoading = false
                self.errorMessage = error.localizedDescription.isEmpty ? L10n.ArtistInput.aiErrorGeneric : error.localizedDescription
            }
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
