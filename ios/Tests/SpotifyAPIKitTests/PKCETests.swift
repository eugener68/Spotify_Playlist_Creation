import XCTest
@testable import SpotifyAPIKit

final class PKCETests: XCTestCase {
    func testGeneratorProducesVerifierAndChallenge() {
        let generator = PKCEGenerator(verifierLength: 32)
        let result = generator.makeChallenge()
        XCTAssertFalse(result.verifier.isEmpty)
        XCTAssertFalse(result.challenge.isEmpty)
        #if canImport(CryptoKit)
        XCTAssertEqual(result.method, .s256)
        #else
        XCTAssertEqual(result.method, .plain)
        #endif
    }

    func testAuthorizationSessionBuildsURL() throws {
        let configuration = SpotifyAPIConfiguration(
            clientID: "client",
            redirectURI: URL(string: "autoplaylistbuilder://callback")!,
            scopes: ["user-read-email", "playlist-modify-private"]
        )
        let authenticator = SpotifyPKCEAuthenticator(
            configuration: configuration,
            pkceGenerator: DeterministicPKCEGenerator()
        )
        let session = try authenticator.makeAuthorizationSession()
        XCTAssertEqual(session.state, "state123")
        XCTAssertTrue(session.authorizationURL.absoluteString.contains("code_challenge=challenge"))
    }
}

private struct DeterministicPKCEGenerator: PKCEGenerating {
    func makeChallenge() -> PKCEChallenge {
        PKCEChallenge(verifier: "verifier", challenge: "challenge", method: .plain, state: "state123")
    }
}
