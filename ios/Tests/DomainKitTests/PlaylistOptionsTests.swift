import XCTest
@testable import DomainKit

final class PlaylistOptionsTests: XCTestCase {
    func testDefaultsMatchDesktopBehavior() {
        let options = PlaylistOptions()
        XCTAssertEqual(options.playlistName, "Untitled Playlist")
        XCTAssertTrue(options.dateStamp)
        XCTAssertEqual(options.limitPerArtist, 5)
        XCTAssertEqual(options.maxArtists, 25)
        XCTAssertEqual(options.maxTracks, 100)
        XCTAssertTrue(options.dedupeVariants)
        XCTAssertTrue(options.reuseExisting)
        XCTAssertTrue(options.preferOriginalTracks)
        XCTAssertTrue(options.includeLibraryArtists)
        XCTAssertFalse(options.includeFollowedArtists)
    }
}
