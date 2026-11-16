import CoreGraphics
import Foundation

/// The `element` of `/tap`, `/press`, and `/find`: exact matches on the attributes `/source` reports, and regular
/// expressions on its label and value (`labelMatch`, `valueMatch`), combined with AND.
///
/// Like `RunnerElementTree.swift`, this file is compiled into both the `relay` CLI and the
/// RelayRunnerUITests target, so the matching the runner relies on is covered by the SwiftPM unit tests.
/// The runner builds the tree from the same `snapshot()` as `/source` and only does the touch itself.
struct RunnerElementSelector: Equatable {
  var identifier: String?
  var label: String?
  /// A `/source` type name such as `button` or `textField`.
  var type: String?
  var value: String?
  /// A regular expression that must match somewhere in the label (`labelMatch`); `^` and `$` match it whole.
  var labelMatch: RunnerElementPattern?
  /// The same for the value (`valueMatch`), where an element without one has the empty value.
  var valueMatch: RunnerElementPattern?
  /// Which match to use, counted from 0 in document order; required when more than one element matches.
  /// It counts only the matches `visibility` keeps.
  var index: Int?
  /// Which matches count: all of them (nil), or only those `Visibility` describes. Applied before `index`.
  var visibility: Visibility?

  /// `onscreen: true` and `hittable: true` of the `element` object. A runner from before them rejects them as
  /// unknown keys, so a client never gets an unfiltered answer for a filtered question.
  enum Visibility: String, Equatable {
    /// Elements whose frame shows inside the screen (`RunnerElementNode.touchPoint(in:)`).
    case onscreen
    /// On the screen, and a touch at the center of that part reaches the element (`RunnerElementTree.reaches`).
    case hittable
  }

  static let keys: Set<String> = ["identifier", "label", "type", "value", "labelMatch", "valueMatch", "index", "onscreen", "hittable"]

  /// Parses the `element` object. Unknown keys are rejected so a typo (`id`, `text`) isn't silently
  /// dropped and turned into a broader match.
  init(json: Any) throws {
    guard let object = json as? [String: Any] else { throw RunnerElementSelectorError.notAnObject }
    if let unknown = object.keys.sorted().first(where: { !Self.keys.contains($0) }) {
      throw RunnerElementSelectorError.unknownKey(unknown)
    }
    func string(_ name: String) throws -> String? {
      guard let value = object[name] else { return nil }
      guard let string = value as? String, !string.isEmpty else { throw RunnerElementSelectorError.notAString(name) }
      return string
    }
    identifier = try string("identifier")
    label = try string("label")
    type = try string("type")
    value = try string("value")
    if let type, !Self.isTypeName(type) {
      throw RunnerElementSelectorError.unknownType(type)
    }
    // Both on one attribute is most likely a --label left in when --label-match was added.
    if label != nil, object["labelMatch"] != nil { throw RunnerElementSelectorError.exactAndPattern("label", "labelMatch") }
    if value != nil, object["valueMatch"] != nil { throw RunnerElementSelectorError.exactAndPattern("value", "valueMatch") }
    func pattern(_ name: String) throws -> RunnerElementPattern? {
      try string(name).map { try RunnerElementPattern($0, key: name) }
    }
    labelMatch = try pattern("labelMatch")
    valueMatch = try pattern("valueMatch")
    if let raw = object["index"] {
      guard let number = RunnerRequestValues.number(raw), number >= 0, number <= Double(Int32.max),
            number.rounded() == number else {
        throw RunnerElementSelectorError.invalidIndex
      }
      index = Int(number)
    }
    func flag(_ name: String) throws -> Bool {
      guard let value = object[name] else { return false }
      guard let flag = RunnerRequestValues.bool(value) else { throw RunnerElementSelectorError.notABoolean(name) }
      return flag
    }
    // hittable implies onscreen, so both together are hittable.
    if try flag("hittable") {
      visibility = .hittable
    } else if try flag("onscreen") {
      visibility = .onscreen
    }
    guard identifier != nil || label != nil || type != nil || value != nil || labelMatch != nil || valueMatch != nil else {
      throw RunnerElementSelectorError.empty
    }
  }

  init(
    identifier: String? = nil, label: String? = nil, type: String? = nil, value: String? = nil,
    labelMatch: RunnerElementPattern? = nil, valueMatch: RunnerElementPattern? = nil, index: Int? = nil,
    visibility: Visibility? = nil
  ) {
    self.identifier = identifier
    self.label = label
    self.type = type
    self.value = value
    self.labelMatch = labelMatch
    self.valueMatch = valueMatch
    self.index = index
    self.visibility = visibility
  }

  /// A known case name, or the `type<raw>` name `/source` uses for types newer than the table.
  private static func isTypeName(_ name: String) -> Bool {
    if RunnerElementTree.typeNames.contains(name) { return true }
    guard name.hasPrefix("type"), let raw = UInt(name.dropFirst(4)) else { return false }
    return RunnerElementTree.typeName(rawValue: raw) == name
  }

  func matches(_ node: RunnerElementNode) -> Bool {
    if let identifier, node.identifier != identifier { return false }
    if let label, node.label != label { return false }
    if let type, node.type != type { return false }
    if let value, node.value != value { return false }
    if let labelMatch, !labelMatch.matches(node.label) { return false }
    if let valueMatch, !valueMatch.matches(node.matchedValue) { return false }
    return true
  }

  /// Throws `patternTooSlow` when `labelMatch` and `valueMatch` take more than `RunnerElementPattern.timeBudget`
  /// over every label and value in the tree. The runner calls it on each snapshot before matching, so a pattern
  /// that backtracks without end (`(a+)+$`) fails the request instead of holding the runner; the matching after
  /// it then reads the same strings and takes no longer.
  func checkPatternTime(in root: RunnerElementNode, budget: TimeInterval = RunnerElementPattern.timeBudget) throws {
    guard labelMatch != nil || valueMatch != nil else { return }
    let deadline = Date(timeIntervalSinceNow: budget)
    func visit(_ node: RunnerElementNode) throws {
      if let labelMatch, labelMatch.matches(node.label, before: deadline) == nil {
        throw RunnerElementSelectorError.patternTooSlow("labelMatch")
      }
      if let valueMatch, valueMatch.matches(node.matchedValue, before: deadline) == nil {
        throw RunnerElementSelectorError.patternTooSlow("valueMatch")
      }
      for child in node.children { try visit(child) }
    }
    try visit(root)
  }

  /// The snapshot path of the element a touch at a point would reach, nil when the hit test has no answer there.
  typealias HitTest = (CGPoint) -> [Int]?

  /// Every matching element in document order (depth first, parents before children) that `visibility` keeps,
  /// numbered in that order, ignoring `index`. With `screen` (points in the displayed orientation), each match
  /// says whether it is `onscreen`; without it, as when the frames aren't on the screen (an iPad window that
  /// can't be placed), it says nothing, and `visibility` keeps nothing. `hittable` asks `hitTest` about the
  /// matches on the screen only; without `hitTest` none of them is kept, so check first that it can answer.
  func allMatches(in root: RunnerElementNode, screen: CGRect? = nil, hitTest: HitTest? = nil) -> [RunnerElementMatch] {
    var matches: [RunnerElementMatch] = []
    func visit(_ node: RunnerElementNode, path: [Int]) {
      if self.matches(node) {
        var element = node
        element.children = []
        let path = node.snapshotPath ?? path
        let point = screen.flatMap(node.touchPoint(in:))
        if keeps(path: path, point: point, screen: screen, in: root, hitTest: hitTest) {
          var match = RunnerElementMatch(index: matches.count, node: element, path: path)
          match.onscreen = screen.map { _ in point != nil }
          matches.append(match)
        }
      }
      for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
    }
    visit(root, path: [])
    return matches
  }

  /// Whether `visibility` keeps the match at `path`, whose touch point on the screen is `point`.
  private func keeps(path: [Int], point: CGPoint?, screen: CGRect?, in root: RunnerElementNode, hitTest: HitTest?) -> Bool {
    switch visibility {
    case nil: return true
    case .onscreen?: return point != nil
    case .hittable?:
      guard let point, let hitTest else { return false }
      return RunnerElementTree.reaches(hitPath: hitTest(point), target: path, at: point, in: root)
    }
  }

  /// The matches `/find` reports: all of them, or only the one `index` picks.
  func matches(in root: RunnerElementNode, screen: CGRect? = nil, hitTest: HitTest? = nil) -> [RunnerElementMatch] {
    picked(from: allMatches(in: root, screen: screen, hitTest: hitTest))
  }

  /// `matches` (from `allMatches`), or only the one `index` picks.
  func picked(from matches: [RunnerElementMatch]) -> [RunnerElementMatch] {
    guard let index else { return matches }
    return matches.indices.contains(index) ? [matches[index]] : []
  }

  /// The element to touch and where. The point is the center of the part of the frame inside `screen`
  /// (points in the displayed orientation), so a cell half under the screen edge is still hit. `visibility`
  /// leaves out matches first, so `index` and the ambiguity count only those kept.
  func resolve(
    in root: RunnerElementNode, screen: CGRect, hitTest: HitTest? = nil
  ) -> Result<RunnerElementTarget, RunnerElementLookupFailure> {
    let matches = allMatches(in: root, screen: screen, hitTest: hitTest)
    let match: RunnerElementMatch
    switch (matches.count, index) {
    case (0, _):
      return .failure(RunnerElementLookupFailure(reason: .notFound, count: 0, candidates: []))
    case (_, let index?):
      guard matches.indices.contains(index) else {
        return .failure(RunnerElementLookupFailure(reason: .indexOutOfRange, count: matches.count, candidates: matches))
      }
      match = matches[index]
    case (1, nil):
      match = matches[0]
    case (_, nil):
      return .failure(RunnerElementLookupFailure(reason: .ambiguous, count: matches.count, candidates: matches))
    }

    // Its frame says nothing about the screen, so neither its size nor where it is can be checked.
    guard match.node.positionUnknown == nil else {
      return .failure(RunnerElementLookupFailure(reason: .positionUnknown, count: matches.count, candidates: [match]))
    }
    let frame = match.node.frame
    guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite else {
      return .failure(RunnerElementLookupFailure(reason: .emptyFrame, count: matches.count, candidates: [match]))
    }
    let visible = match.node.visibleFrame(in: screen)
    guard !visible.isNull, visible.width > 0, visible.height > 0 else {
      return .failure(RunnerElementLookupFailure(reason: .offscreen, count: matches.count, candidates: [match]))
    }
    guard match.node.enabled else {
      return .failure(RunnerElementLookupFailure(reason: .disabled, count: matches.count, candidates: [match]))
    }
    return .success(RunnerElementTarget(match: match, point: CGPoint(x: visible.midX, y: visible.midY), count: matches.count))
  }
}

enum RunnerElementSelectorError: Error, Equatable, CustomStringConvertible {
  case notAnObject
  case empty
  case unknownKey(String)
  case notAString(String)
  case unknownType(String)
  case invalidIndex
  case notABoolean(String)
  /// The exact key and the pattern key of one attribute (`label` and `labelMatch`).
  case exactAndPattern(String, String)
  case invalidPattern(String)
  case patternTooLong(String)
  case patternTooSlow(String)

  var description: String {
    switch self {
    case .notAnObject: return "element: expected an object"
    case .empty: return "element: expected at least one of identifier, label, type, value, labelMatch, valueMatch"
    case .unknownKey(let key):
      return "element: unknown key '\(key)' (expected identifier, label, type, value, labelMatch, valueMatch, index, onscreen, "
        + "hittable)"
    case .notAString(let key): return "element.\(key): expected a non-empty string"
    case .unknownType(let type): return "element.type: unknown type '\(type)' (use the type names of /source)"
    case .invalidIndex: return "element.index: expected a non-negative integer"
    case .notABoolean(let key): return "element.\(key): expected true or false"
    case .exactAndPattern(let exact, let pattern):
      return "element: \(exact) and \(pattern) cannot be combined (\(exact) matches exactly; write ^...$ in \(pattern) for that)"
    case .invalidPattern(let key): return "element.\(key): not a valid regular expression (ICU syntax, as NSRegularExpression)"
    case .patternTooLong(let key):
      return "element.\(key): the regular expression is longer than \(RunnerElementPattern.maxLength) characters"
    case .patternTooSlow(let key):
      return "element.\(key): the regular expression took more than \(Int(RunnerElementPattern.timeBudget)) s over the elements on "
        + "the screen; write one that backtracks less (no nested repeats such as (a+)+)"
    }
  }
}

enum RunnerFindGoneError: Error, Equatable, CustomStringConvertible {
  case notABoolean
  case withIndex

  var description: String {
    switch self {
    case .notABoolean: return "gone: expected true or false"
    case .withIndex: return "gone: cannot be combined with element.index (it waits for every match to go)"
    }
  }
}

struct RunnerElementMatch: Sendable {
  /// The position among all matches in document order, the value to pass as `index`. With `visibility`, among
  /// the matches it keeps.
  var index: Int
  /// The element without its children.
  var node: RunnerElementNode
  /// Whether its frame shows inside the screen; nil when the frames can't be placed on the screen (not in the JSON then).
  var onscreen: Bool?

  /// Identity within the snapshot; attributes and frames need not be unique. Not serialized.
  var path: [Int] = []

  /// The summary `/find`, `/tap`, and lookup errors return for an element.
  var json: [String: Any] {
    var object: [String: Any] = [
      "index": index,
      "type": node.type,
      "identifier": node.identifier,
      "label": node.label,
      "value": node.value ?? NSNull(),
      "frame": RunnerElementTree.json(node.frame),
      "enabled": node.enabled
    ]
    object["onscreen"] = onscreen
    return object
  }
}

struct RunnerElementTarget {
  var match: RunnerElementMatch
  var point: CGPoint
  var count: Int = 1

  /// Refuse only a control positively identified on an unrelated branch in this snapshot. An unavailable hit test
  /// or an element absent from the tree (for example a remote view) preserves the existing touch.
  func verified(hitTest: (CGPoint) -> [Int]?, in root: RunnerElementNode) -> Result<RunnerElementTarget, RunnerElementLookupFailure> {
    verified(hitPath: hitTest(point), in: root)
  }

  /// `verified(hitTest:in:)` with the path hit at `point` already known.
  func verified(hitPath: [Int]?, in root: RunnerElementNode) -> Result<RunnerElementTarget, RunnerElementLookupFailure> {
    guard let hitPath, !RunnerElementTree.isRelatedHit(hitPath, to: match.path),
          let hit = RunnerElementTree.hitControl(at: point, path: hitPath, in: root) else { return .success(self) }
    return .failure(RunnerElementLookupFailure(reason: .pointCovered, count: count, candidates: [match], hit: hit))
  }
}

/// Why a selector didn't lead to one element that can be touched; the runner answers 422 with `json`.
struct RunnerElementLookupFailure: Error {
  enum Reason: String {
    case notFound
    case ambiguous
    case indexOutOfRange
    case emptyFrame
    case offscreen
    case disabled
    case pointCovered
    /// The element is inside a view another process draws (the share sheet), and where it is on the screen
    /// can't be told (`RunnerRemoteViews`). Nothing was sent.
    case positionUnknown
  }

  /// How many candidates the error lists.
  static let candidateLimit = 5

  var reason: Reason
  /// The number of elements the selector matched, ignoring `index`.
  var count: Int
  /// All matches for ambiguous and indexOutOfRange; the chosen element for the other reasons.
  var candidates: [RunnerElementMatch]
  /// The known receiver at the touch point, for pointCovered only.
  var hit: RunnerElementNode? = nil

  /// Waiting can make an element appear, scroll into view, or become enabled, but more matches won't
  /// go away by themselves, so an ambiguous selector fails without waiting out the timeout.
  var isRetryable: Bool { reason != .ambiguous }

  var message: String {
    switch reason {
    case .notFound: return "no element matches the selector"
    case .ambiguous: return "\(count) elements match the selector; add conditions or an index"
    case .indexOutOfRange: return "index is out of range: \(count) elements match the selector"
    case .emptyFrame: return "the element has an empty frame"
    case .offscreen: return "the element is outside the screen"
    case .disabled: return "the element is disabled"
    case .pointCovered: return "the touch point hits another control; nothing was sent"
    case .positionUnknown:
      return RunnerRemoteViews.touchError(candidates.first?.node.positionUnknown ?? "cannot tell where the element is on the screen")
    }
  }

  /// `reason` says more; the code groups the reasons by what to do next.
  var code: RunnerErrorCode {
    switch reason {
    case .notFound, .indexOutOfRange: return .elementNotFound
    case .ambiguous: return .elementAmbiguous
    case .emptyFrame, .offscreen, .disabled: return .elementNotHittable
    case .pointCovered: return .elementPointCovered
    case .positionUnknown: return .remoteViewPositionUnknown
    }
  }

  var json: [String: Any] {
    var body: [String: Any] = [
      "ok": false,
      "code": code.rawValue,
      "error": message,
      "reason": reason.rawValue,
      "count": count,
      "candidates": candidates.prefix(Self.candidateLimit).map(\.json)
    ]
    if let hit {
      body["hit"] = ["type": hit.type, "label": hit.label, "frame": RunnerElementTree.json(hit.frame)]
    }
    return body
  }
}

enum RunnerElementLookup {
  /// The longest `timeout`. A waiting command holds the busy gate, so every other request gets 409 meanwhile.
  static let maxTimeout: TimeInterval = 10
  /// How often the runner snapshots again while waiting.
  static let pollInterval: TimeInterval = 0.25
  static let defaultFindLimit = 20
  static let maxFindLimit = 100

  /// The optional `timeout` in seconds: 0 (one attempt) when absent, nil unless a number in 0...maxTimeout.
  static func timeout(_ value: Any?) -> TimeInterval? {
    guard let value else { return 0 }
    guard let timeout = RunnerRequestValues.number(value), (0 ... maxTimeout).contains(timeout) else { return nil }
    return timeout
  }

  /// The optional `limit` of `/find`: an integer in 1...maxFindLimit, nil when invalid.
  static func findLimit(_ value: Any?) -> Int? {
    guard let value else { return defaultFindLimit }
    guard let limit = RunnerRequestValues.number(value), limit.rounded() == limit,
          (1 ... Double(maxFindLimit)).contains(limit) else { return nil }
    return Int(limit)
  }

  /// The `/find` body: `count` (every match, ignoring `index`) and at most `limit` of `matches`. A `gone`
  /// lookup adds `gone`: whether nothing matched in the end. A client that sent `gone` and finds no `gone` in
  /// the answer is talking to a runner that predates it, which waited for an element to appear instead.
  static func findJSON(_ matches: [RunnerElementMatch], count: Int, limit: Int, bundleID: String, gone: Bool = false) -> [String: Any] {
    var object: [String: Any] = [
      "ok": true,
      "bundleId": bundleID,
      "count": count,
      "elements": matches.prefix(limit).map(\.json),
      "truncated": matches.count > limit
    ]
    if gone {
      object["gone"] = matches.isEmpty
    }
    return object
  }

  /// The optional `gone` of `/find`: false when absent, nil unless a JSON boolean. It waits for no element to
  /// match, so it can't be combined with `index`, whose element would change as the others go.
  static func gone(_ value: Any?, selector: RunnerElementSelector) -> Result<Bool, RunnerFindGoneError> {
    guard let value else { return .success(false) }
    guard let gone = RunnerRequestValues.bool(value) else { return .failure(.notABoolean) }
    if gone, selector.index != nil {
      return .failure(.withIndex)
    }
    return .success(gone)
  }

  /// Whether a `/find` that looked at `matches` (picked by `index`) is done: when something matches, or with
  /// `gone` when nothing does, or on the last attempt whatever it found.
  static func findIsDone(matchCount: Int, gone: Bool, isLastAttempt: Bool) -> Bool {
    isLastAttempt || (gone ? matchCount == 0 : matchCount > 0)
  }
}

/// A `labelMatch` or `valueMatch`: an ICU regular expression (`NSRegularExpression` with no options) that must match
/// somewhere in the string. Options go in the pattern: `(?i)` ignores case, `(?s)` lets `.` match a line break, and
/// `(?m)` makes `^` and `$` match at each line; without `(?m)` they match at the start and the end of the whole
/// string (`$` also before a line break that ends it). The CLI and the runner both build it here.
struct RunnerElementPattern: Equatable, @unchecked Sendable {
  /// The longest pattern, in characters. Longer ones are more likely pasted by mistake than written.
  static let maxLength = 1000
  /// How long `labelMatch` and `valueMatch` together may take over one snapshot (`checkPatternTime`).
  static let timeBudget: TimeInterval = 1

  let pattern: String
  private let expression: NSRegularExpression

  /// `key` names the field in the error (`labelMatch`, `valueMatch`).
  init(_ pattern: String, key: String = "pattern") throws {
    guard pattern.count <= Self.maxLength else { throw RunnerElementSelectorError.patternTooLong(key) }
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      throw RunnerElementSelectorError.invalidPattern(key)
    }
    self.pattern = pattern
    self.expression = expression
  }

  func matches(_ string: String) -> Bool {
    expression.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
  }

  /// `matches`, or nil when it runs past `deadline`. ICU reports progress while it backtracks, so a pattern that
  /// would take minutes on one string is stopped too.
  func matches(_ string: String, before deadline: Date) -> Bool? {
    guard Date() < deadline else { return nil }
    var found = false
    var late = false
    expression.enumerateMatches(in: string, options: [.reportProgress], range: NSRange(location: 0, length: (string as NSString).length)) { match, _, stop in
      if match != nil {
        found = true
        stop.pointee = true
      } else if Date() >= deadline {
        late = true
        stop.pointee = true
      }
    }
    return late && !found ? nil : found
  }

  static func == (lhs: RunnerElementPattern, rhs: RunnerElementPattern) -> Bool {
    lhs.pattern == rhs.pattern
  }
}

extension RunnerElementNode {
  /// The value a `valueMatch` reads: the empty string for an element without one, as `--format compact` shows it.
  var matchedValue: String { value ?? "" }
}

extension RunnerElementSelector {
  /// The `element` object of `/tap`, `/press`, and `/find`.
  var json: [String: Any] {
    var object: [String: Any] = [:]
    object["identifier"] = identifier
    object["label"] = label
    object["type"] = type
    object["value"] = value
    object["labelMatch"] = labelMatch?.pattern
    object["valueMatch"] = valueMatch?.pattern
    object["index"] = index
    object["onscreen"] = visibility == .onscreen ? true : nil
    object["hittable"] = visibility == .hittable ? true : nil
    return object
  }
}
