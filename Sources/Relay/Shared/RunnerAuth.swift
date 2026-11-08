import CryptoKit
import Foundation
import Security

/// Bearer-token authentication between `relay` and the on-device runner.
///
/// This file is compiled into both the `relay` CLI and the RelayRunnerUITests target, so the header
/// parsing and comparison the runner relies on are covered by the SwiftPM unit tests.
enum RunnerAuth {
  /// The variable the runner reads: the SHA-256 of the token, not the token itself, because xcodebuild
  /// records the test environment in the xcresult bundle. xcodebuild receives it with the
  /// `TEST_RUNNER_` prefix.
  static let tokenHashEnvironmentKey = "RELAY_RUNNER_TOKEN_SHA256"
  static let tokenByteCount = 32

  /// A new token: 32 bytes from the system CSPRNG, hex-encoded (64 characters).
  static func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: tokenByteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Lowercase hex SHA-256 of the token's UTF-8 bytes (64 characters).
  static func tokenHash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The hash from the environment in canonical form, or nil unless it is 64 hex digits.
  static func normalizedTokenHash(_ value: String) -> String? {
    let hash = value.trimmingCharacters(in: .whitespaces).lowercased()
    guard hash.utf8.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
    return hash
  }

  static func authorizationHeader(token: String) -> String {
    "Bearer \(token)"
  }

  /// The token in an `Authorization: Bearer <token>` header value, or nil when the header is missing,
  /// uses another scheme, or carries no token. The scheme is case-insensitive (RFC 9110).
  static func bearerToken(fromAuthorizationHeader header: String?) -> String? {
    guard let header else { return nil }
    let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
    let token = parts[1].trimmingCharacters(in: .whitespaces)
    return token.isEmpty ? nil : token
  }

  /// Compares in time that depends only on the lengths, never on where the first mismatch is.
  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: a.count ^ b.count) | (a.count == b.count ? 0 : 1)
    for index in 0 ..< max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0
      let y = index < b.count ? b[index] : 0
      difference |= x ^ y
    }
    return difference == 0
  }

  /// True when the bearer token hashes to `tokenHash` (a normalized hash). Hashing first also makes
  /// the comparison length-independent: both sides are always 64 characters.
  static func isAuthorized(authorizationHeader header: String?, tokenHash: String) -> Bool {
    guard let presented = bearerToken(fromAuthorizationHeader: header) else { return false }
    return constantTimeEquals(self.tokenHash(presented), tokenHash)
  }
}
