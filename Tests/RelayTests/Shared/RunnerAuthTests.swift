import Foundation
@testable import Relay
import Testing

struct RunnerAuthTests {
    @Test func generatesDistinct32ByteHexTokens() {
        let tokens = (0..<20).map { _ in RunnerAuth.generateToken() }
        for token in tokens {
            #expect(token.count == RunnerAuth.tokenByteCount * 2)
            #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func parsesBearerHeader() {
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "Bearer abc123") == "abc123")
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "bearer abc123") == "abc123")
        #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: "  Bearer   abc123  ") == "abc123")
        #expect(RunnerAuth.authorizationHeader(token: "abc") == "Bearer abc")
    }

    @Test func rejectsMalformedHeaders() {
        for header in [nil, "", "Bearer", "Bearer ", "Basic abc123", "abc123", "Bearerabc123"] {
            #expect(RunnerAuth.bearerToken(fromAuthorizationHeader: header) == nil)
        }
    }

    @Test func comparesTokens() {
        #expect(RunnerAuth.constantTimeEquals("abc", "abc"))
        #expect(RunnerAuth.constantTimeEquals("", ""))
        #expect(!RunnerAuth.constantTimeEquals("abc", "abd"))
        #expect(!RunnerAuth.constantTimeEquals("abc", "ab"))
        #expect(!RunnerAuth.constantTimeEquals("ab", "abc"))
        #expect(!RunnerAuth.constantTimeEquals("", "a"))
        // A prefix padded with NUL bytes must not match through the zero padding.
        #expect(!RunnerAuth.constantTimeEquals("abc", "abc\u{0}"))
    }

    @Test func authorizesOnlyTheMatchingBearerToken() {
        let token = RunnerAuth.generateToken()
        let hash = RunnerAuth.tokenHash(token)
        #expect(RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(token)", tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: nil, tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(RunnerAuth.generateToken())", tokenHash: hash))
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Basic \(token)", tokenHash: hash))
        // Knowing the hash (e.g. from an xcresult bundle) is not enough to authenticate.
        #expect(!RunnerAuth.isAuthorized(authorizationHeader: "Bearer \(hash)", tokenHash: hash))
    }

    @Test func hashesTokensWithSHA256() {
        // FIPS 180-2 test vector.
        #expect(RunnerAuth.tokenHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let token = RunnerAuth.generateToken()
        #expect(RunnerAuth.tokenHash(token) == RunnerAuth.tokenHash(token))
        #expect(RunnerAuth.tokenHash(token) != token)
    }

    @Test func normalizesTheHashFromTheEnvironment() {
        let hash = RunnerAuth.tokenHash("abc")
        #expect(RunnerAuth.normalizedTokenHash(hash) == hash)
        #expect(RunnerAuth.normalizedTokenHash(" \(hash.uppercased()) ") == hash)
        for invalid in ["", "abc", String(hash.dropLast()), hash + "0", String(hash.dropLast()) + "g"] {
            #expect(RunnerAuth.normalizedTokenHash(invalid) == nil, "\(invalid)")
        }
    }
}
