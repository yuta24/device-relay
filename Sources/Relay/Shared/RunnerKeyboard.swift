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
}
