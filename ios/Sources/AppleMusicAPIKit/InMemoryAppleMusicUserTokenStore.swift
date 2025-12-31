import Foundation

public actor InMemoryAppleMusicUserTokenStore: AppleMusicUserTokenStoring {
    private var token: String?

    public init(initial: String? = nil) {
        self.token = initial
    }

    public func load() async throws -> String? {
        token
    }

    public func save(_ token: String) async throws {
        self.token = token
    }

    public func clear() async throws {
        token = nil
    }
}
