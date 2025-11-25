import Foundation
import XCTest
@testable import SpotifyAPIKit

#if canImport(Security)
final class KeychainTokenStoreTests: XCTestCase {
    func testLoadMissingReturnsNil() async throws {
        let store = makeStore()
        let token = try await store.load()
        XCTAssertNil(token)
    }

    func testRoundTripSaveAndLoad() async throws {
        let store = makeStore()
        let expected = token()
        try await store.save(expected)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, expected)
    }

    func testClearRemovesStoredToken() async throws {
        let store = makeStore()
        try await store.save(token())
        try await store.clear()
        let loaded = try await store.load()
        XCTAssertNil(loaded)
    }

    private func makeStore(file: StaticString = #file, line: UInt = #line) -> KeychainTokenStore {
        let unique = UUID().uuidString
        return KeychainTokenStore(
            service: "autoplaylistbuilder.tests.\(unique)",
            account: unique
        )
    }

    private func token() -> SpotifyTokenSet {
        SpotifyTokenSet(
            accessToken: "access-\(UUID().uuidString)",
            refreshToken: "refresh-\(UUID().uuidString)",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "playlist-modify-private",
            tokenType: "Bearer"
        )
    }
}
#endif
