import Foundation

/// `/open` (and `relay open`): which URLs it takes, and when the app that opens one has come to the foreground.
///
/// Like `RunnerAuth.swift`, this file is compiled into both the `relay` CLI and the runner target so the
/// SwiftPM unit tests cover it.
enum RunnerOpen {
  /// How long the runner waits for the system to accept the URL (the private path's completion).
  static let acceptWait: TimeInterval = 30
  /// How long the runner then waits for the app that opens the URL to come to the foreground. A cold start
  /// of a small app took about 3 s on the simulator; the app the URL goes to may already be in front, and
  /// then nothing changes and the whole wait passes.
  static let foregroundWait: TimeInterval = 5

  /// `url` as a URL, or why it can't be opened as given. It must be absolute (`https://…`, `myapp://…`) and
  /// written as it is sent: a space or another character that isn't allowed in a URL is rejected rather than
  /// percent-encoded here, so the app receives exactly the URL in the request.
  static func url(_ text: String) -> Result<URL, URLProblem> {
    guard !text.isEmpty else { return .failure(.empty) }
    let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    if let scalar = text.unicodeScalars.first(where: { disallowed.contains($0) }) {
      return .failure(.invalidCharacter(String(format: "U+%04X", scalar.value)))
    }
    guard let url = URL(string: text, encodingInvalidCharacters: false) else { return .failure(.malformed) }
    guard let scheme = url.scheme, !scheme.isEmpty else { return .failure(.noScheme) }
    return .success(url)
  }

  enum URLProblem: Error, Equatable, CustomStringConvertible {
    case empty
    case invalidCharacter(String)
    case malformed
    case noScheme

    var description: String {
      switch self {
      case .empty: return "url: must not be empty"
      case .invalidCharacter(let character):
        return "url: contains \(character), which a URL can't have; percent-encode it (a space is %20)"
      case .malformed:
        return "url: not a valid URL; percent-encode characters such as spaces, quotes, and non-ASCII letters"
      case .noScheme: return "url: needs a scheme, such as https:// or the app's own (myapp://)"
      }
    }
  }

  /// Whether the app that opens the URL is in the foreground: `bundleID` when the request names one, otherwise
  /// any app other than `before`, the foreground app when the URL was sent (in the middle of an app switch the
  /// new app is the foreground app already, see `RunnerWindows.foregroundIndex`).
  static func hasArrived(foreground: String, before: String, bundleID: String?) -> Bool {
    if let bundleID {
      return foreground == bundleID
    }
    return foreground != before
  }

  /// LaunchServices' error when no installed app handles the URL's scheme (`tel:` on a simulator, a custom
  /// scheme whose app isn't installed).
  static let noHandlerErrorDomain = "LSApplicationWorkspaceErrorDomain"
  static let noHandlerErrorCode = 115

  /// Why the system refused the URL, for people: a plain sentence for "no app handles it", otherwise the
  /// system's own message without its final period.
  static func reason(domain: String, code: Int, description: String, scheme: String?) -> String {
    if domain == noHandlerErrorDomain, code == noHandlerErrorCode {
      return "no installed app handles \(scheme.map { "the scheme \($0):" } ?? "this URL")"
    }
    var text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix(".") {
      text.removeLast()
    }
    return text
  }

  /// The `error` of an `open_failed` answer.
  static func failureMessage(url: String, bundleID: String?, reason: String) -> String {
    let opener = bundleID.map { " with \($0)" } ?? ""
    return "could not open \(url)\(opener): \(reason)"
  }

  static func acceptTimeoutMessage(url: String) -> String {
    "the system did not answer within \(Int(acceptWait)) s whether it opened \(url); check the screen with relay foreground"
  }
}
