import Combine
import Foundation
import DomainKit

@MainActor
public final class PlaylistBuilderViewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastResult: PlaylistResult?
    @Published public private(set) var errorMessage: String?

    private let playlistBuilder: PlaylistBuilder
    private var buildTask: Task<Void, Never>?

    public init(playlistBuilder: PlaylistBuilder) {
        self.playlistBuilder = playlistBuilder
    }

    deinit {
        buildTask?.cancel()
    }

    public func run(options: PlaylistOptions) {
        buildTask?.cancel()
        errorMessage = nil
        isRunning = true

        buildTask = Task { [weak self] in
            guard let self else { return }
            await self.performBuild(options: options)
        }
    }

    private func performBuild(options: PlaylistOptions) async {
        defer { isRunning = false }
        do {
            let context = PlaylistBuilderContext(options: options)
            let result = try await playlistBuilder.build(with: context)
            lastResult = result
        } catch is CancellationError {
            // Ignore cancellation because a new run has been requested.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
