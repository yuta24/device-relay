import Foundation

/// Special keys for `/key` and the `keys` array of `/type`.
///
/// This file is compiled into both the `relay` CLI and the RelayRunnerUITests target, so the name
/// parsing the runner relies on is covered by the SwiftPM unit tests. The runner maps each case to an
/// `XCUIKeyboardKey`.
///
/// Only keys that work on iPhone are offered. Tab and escape are left out: the software keyboard has
/// neither key, so tab was typed as a "\t" character and escape did nothing (simulator and device).
enum RunnerKey: String, CaseIterable {
  case `return`
  case delete
  case space

  /// Case-insensitive, with a few common aliases (`enter`, `backspace`).
  init?(name: String) {
    switch name.lowercased() {
    case "return", "enter": self = .return
    case "delete", "backspace": self = .delete
    case "space": self = .space
    default: return nil
    }
  }

  /// The keys of a JSON `keys` array, in order. Throws unless every entry is a known key name.
  static func parse(_ value: Any) throws -> [RunnerKey] {
    guard let names = value as? [Any] else {
      throw RunnerKeyError.notAnArray
    }
    return try names.map { item in
      guard let name = item as? String else { throw RunnerKeyError.notAString }
      guard let key = RunnerKey(name: name) else { throw RunnerKeyError.unknownKey(name) }
      return key
    }
  }

  static var supportedNames: String {
    allCases.map(\.rawValue).joined(separator: ", ")
  }
}

enum RunnerKeyError: Error, Equatable, CustomStringConvertible {
  case notAnArray
  case notAString
  case unknownKey(String)

  var description: String {
    switch self {
    case .notAnArray: return "keys: expected an array of key names"
    case .notAString: return "keys: expected key names as strings"
    case .unknownKey(let name): return "key: unsupported key '\(name)' (expected \(RunnerKey.supportedNames))"
    }
  }
}

enum RunnerTextError: Error, Equatable {
  case missing
  case notAString
}

enum RunnerTyping {
  /// The `text` of a `/type` body, typed before `keyCount` keys. Without keys it is required and must
  /// not be empty. With keys it may be absent or empty, but a value that is present must be a string,
  /// so `{"text": 123, "keys": ["return"]}` is rejected instead of pressing only Return.
  static func text(_ value: Any?, keyCount: Int) throws -> String {
    guard let value else {
      guard keyCount > 0 else { throw RunnerTextError.missing }
      return ""
    }
    guard let text = value as? String else { throw RunnerTextError.notAString }
    guard !text.isEmpty || keyCount > 0 else { throw RunnerTextError.missing }
    return text
  }

  /// True when an XCUI issue says that nothing in the app has keyboard focus, as `typeText` reports
  /// with "Neither element nor any descendant has keyboard focus".
  static func isMissingKeyboardFocus(_ issue: String) -> Bool {
    issue.range(of: "has keyboard focus", options: .caseInsensitive) != nil
  }

  static func missingKeyboardFocusMessage(bundleID: String) -> String {
    "no element has keyboard focus in \(bundleID)"
  }

  enum FocusCheck: Equatable {
    case focused
    /// The query recorded an XCUI issue (the app isn't running, say): nothing may be typed, since synthesized
    /// text goes to whatever has focus.
    case queryFailed
    case notFocused
  }

  /// What one look for keyboard focus found before synthesized text is sent. A failed query wins over a count,
  /// since the count of a failed query means nothing.
  static func focusCheck(matchCount: Int, queryFailed: Bool) -> FocusCheck {
    if queryFailed { return .queryFailed }
    return matchCount > 0 ? .focused : .notFocused
  }

  /// Seconds per character that typing may take. It typed about 15 ms per character on a simulator (1,000
  /// ASCII characters in 17 s, Japanese at the same rate); a device is slower (one `/key` took 0.66 s there
  /// against 0.26 s on a simulator), so this leaves several times what was seen.
  static let waitPerCharacter: TimeInterval = 0.1
  /// Seconds per key (`/key`, `/type` `keys`): a key took 0.26 s on a simulator and 0.66 s on a device.
  static let waitPerKey: TimeInterval = 1

  /// How long typing `text` and then `keyCount` keys may take. `relay type` waits 30 s more than this for the
  /// answer; the runner gives synthesized text this plus `synthesisGrace`, so it answers first.
  /// Counted in Unicode scalars, not characters, since a character made of several scalars can take
  /// several key events.
  static func wait(text: String, keyCount: Int) -> TimeInterval {
    Double(text.unicodeScalars.count) * waitPerCharacter + Double(keyCount) * waitPerKey
  }

  /// What the runner adds to `wait(text:keyCount:)` before it stops waiting for synthesized text to be typed.
  static let synthesisGrace: TimeInterval = 10

  static func synthesisTimeoutMessage(seconds: TimeInterval) -> String {
    "typing did not complete within \(Int(seconds.rounded(.up)))s; some of the text may have been typed"
  }

  /// Characters per second for synthesized text: `XCUIElement.typeText` uses 60 when none is set.
  static let typingSpeed = 60
}
