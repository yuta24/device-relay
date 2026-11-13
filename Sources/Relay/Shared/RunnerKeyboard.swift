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
  /// The `text` of a `/type` body, typed before `keyCount` keys. Without keys or `clear` it is required
  /// and must not be empty. With them it may be absent or empty, but a value that is present must be a
  /// string, so `{"text": 123, "keys": ["return"]}` is rejected instead of pressing only Return.
  static func text(_ value: Any?, keyCount: Int, clear: Bool = false) throws -> String {
    let mayBeEmpty = keyCount > 0 || clear
    guard let value else {
      guard mayBeEmpty else { throw RunnerTextError.missing }
      return ""
    }
    guard let text = value as? String else { throw RunnerTextError.notAString }
    guard !text.isEmpty || mayBeEmpty else { throw RunnerTextError.missing }
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

  /// How long `/type`'s `clear` may take at most: the keys of both steps (command-A, a delete, command-down)
  /// and `RunnerClearing.maxDeletes` deletes. `relay type --clear` waits this much longer for the answer.
  static let clearWait: TimeInterval = 3 * waitPerKey + Double(RunnerClearing.maxDeletes) * waitPerCharacter

  static func synthesisTimeoutMessage(seconds: TimeInterval) -> String {
    "typing did not complete within \(Int(seconds.rounded(.up)))s; some of the text may have been typed"
  }

  /// Characters per second for synthesized text: `XCUIElement.typeText` uses 60 when none is set.
  static let typingSpeed = 60
}

/// `/type`'s `clear`: empties the field with keyboard focus before the text is typed, and checks it is empty.
///
/// Select all and delete comes first: it does not depend on where the cursor is or on how many characters a
/// delete takes away, and takes the same time for any length. Select all is a hardware key event (command-A);
/// when it does not take (the field or app ignores it), the cursor goes to the end (command-down) and a delete
/// goes per character left, which works too wherever the cursor is moved to the end. A delete takes away one
/// character as Swift counts them (an emoji with joiners, a letter with combining marks, one Japanese
/// character); a delete too many does nothing in an empty field.
///
/// The steps and the reads are closures, so this runs in the SwiftPM unit tests; the runner sends the keys.
enum RunnerClearing {
  /// What the field with keyboard focus holds, as its snapshot says.
  struct Field: Equatable {
    var value: String?
    var placeholder: String?

    init(value: String?, placeholder: String? = nil) {
      self.value = value
      self.placeholder = placeholder
    }

    /// Nothing in it at all. A field that shows its placeholder may report it as the value, but it may also
    /// hold that very text, so a value equal to the placeholder only counts as empty after clearing.
    var hasNoValue: Bool { value?.isEmpty ?? true }

    /// Empty after clearing: no value, or the placeholder as its value.
    var isClear: Bool {
      guard let value, !value.isEmpty else { return true }
      return value == placeholder
    }

    /// The characters a delete per character has to take away. A password field reports one dot each.
    var characterCount: Int { value?.count ?? 0 }
  }

  enum Step: Equatable {
    /// Command-A, then one delete.
    case selectAllAndDelete
    /// Command-down (to the end, the last line too), then `count` deletes.
    case moveToEndAndDelete(count: Int)
  }

  enum Outcome: Equatable {
    /// The field had nothing to clear; nothing was sent.
    case alreadyEmpty
    /// The field is empty after `steps` steps.
    case cleared(steps: [Step])
  }

  /// The field is not empty after every step; nothing more is sent, and the text is not typed.
  struct NotCleared: Error, Equatable {
    let remaining: Int
    let steps: [Step]

    var message: String {
      let deletes = steps.compactMap { step -> Int? in
        if case .moveToEndAndDelete(let count) = step { return count }
        return nil
      }.reduce(0, +)
      return "the field with keyboard focus still has \(remaining) character\(remaining == 1 ? "" : "s") after select all and "
        + "delete, then \(deletes) delete\(deletes == 1 ? "" : "s") from the end; nothing was typed"
    }
  }

  /// The most deletes the second step sends: a field that select all does not clear and that holds more than
  /// this fails with `NotCleared` rather than taking longer than `RunnerTyping.clearWait`.
  static let maxDeletes = 200

  /// How long a read after a step looks again for the field to be empty, every `settleInterval`: the keys
  /// have been delivered when the synthesizer says so, but the app may update the field a little later.
  static let settleWait: TimeInterval = 0.5
  static let settleInterval: TimeInterval = 0.1

  /// `wait` sleeps (spinning the run loop in the runner) between the reads after a step.
  static func clear(read: () throws -> Field, perform: (Step) throws -> Void, wait: (TimeInterval) -> Void) throws -> Outcome {
    let initial = try read()
    guard !initial.hasNoValue else { return .alreadyEmpty }
    var steps: [Step] = []
    var field = initial
    for step in [Step.selectAllAndDelete, .moveToEndAndDelete(count: 0)] {
      let sent = step == .selectAllAndDelete ? step : .moveToEndAndDelete(count: min(field.characterCount, maxDeletes))
      steps.append(sent)
      try perform(sent)
      field = try settled(read: read, wait: wait)
      if field.isClear { return .cleared(steps: steps) }
    }
    throw NotCleared(remaining: field.characterCount, steps: steps)
  }

  /// The field after a step: read until it is clear or `settleWait` has passed.
  private static func settled(read: () throws -> Field, wait: (TimeInterval) -> Void) throws -> Field {
    var field = try read()
    for _ in 0 ..< Int((settleWait / settleInterval).rounded()) where !field.isClear {
      wait(settleInterval)
      field = try read()
    }
    return field
  }
}
