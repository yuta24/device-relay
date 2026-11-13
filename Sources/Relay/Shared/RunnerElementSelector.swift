import CoreGraphics
import Foundation

/// The `element` of `/tap`, `/press`, and `/find`: exact matches on the attributes `/source` reports,
/// combined with AND.
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
  /// Which match to use, counted from 0 in document order; required when more than one element matches.
  var index: Int?

  static let keys: Set<String> = ["identifier", "label", "type", "value", "index"]

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
    if let raw = object["index"] {
      guard let number = RunnerRequestValues.number(raw), number >= 0, number <= Double(Int32.max),
            number.rounded() == number else {
        throw RunnerElementSelectorError.invalidIndex
      }
      index = Int(number)
    }
    guard identifier != nil || label != nil || type != nil || value != nil else {
      throw RunnerElementSelectorError.empty
    }
  }

  init(identifier: String? = nil, label: String? = nil, type: String? = nil, value: String? = nil, index: Int? = nil) {
    self.identifier = identifier
    self.label = label
    self.type = type
    self.value = value
    self.index = index
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
    return true
  }

  /// Every matching element in document order (depth first, parents before children), ignoring `index`.
  func allMatches(in root: RunnerElementNode) -> [RunnerElementMatch] {
    var matches: [RunnerElementMatch] = []
    func visit(_ node: RunnerElementNode, path: [Int]) {
      if self.matches(node) {
        var element = node
        element.children = []
        matches.append(RunnerElementMatch(index: matches.count, node: element, path: node.snapshotPath ?? path))
      }
      for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
    }
    visit(root, path: [])
    return matches
  }

  /// The matches `/find` reports: all of them, or only the one `index` picks.
  func matches(in root: RunnerElementNode) -> [RunnerElementMatch] {
    picked(from: allMatches(in: root))
  }

  /// `matches` (from `allMatches`), or only the one `index` picks.
  func picked(from matches: [RunnerElementMatch]) -> [RunnerElementMatch] {
    guard let index else { return matches }
    return matches.indices.contains(index) ? [matches[index]] : []
  }

  /// The element to touch and where. The point is the center of the part of the frame inside `screen`
  /// (points in the displayed orientation), so a cell half under the screen edge is still hit.
  func resolve(in root: RunnerElementNode, screen: CGRect) -> Result<RunnerElementTarget, RunnerElementLookupFailure> {
    let matches = allMatches(in: root)
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

  var description: String {
    switch self {
    case .notAnObject: return "element: expected an object"
    case .empty: return "element: expected at least one of identifier, label, type, value"
    case .unknownKey(let key): return "element: unknown key '\(key)' (expected identifier, label, type, value, index)"
    case .notAString(let key): return "element.\(key): expected a non-empty string"
    case .unknownType(let type): return "element.type: unknown type '\(type)' (use the type names of /source)"
    case .invalidIndex: return "element.index: expected a non-negative integer"
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
  /// The position among all matches in document order, the value to pass as `index`.
  var index: Int
  /// The element without its children.
  var node: RunnerElementNode

  /// Identity within the snapshot; attributes and frames need not be unique. Not serialized.
  var path: [Int] = []

  /// The summary `/find`, `/tap`, and lookup errors return for an element.
  var json: [String: Any] {
    [
      "index": index,
      "type": node.type,
      "identifier": node.identifier,
      "label": node.label,
      "value": node.value ?? NSNull(),
      "frame": RunnerElementTree.json(node.frame),
      "enabled": node.enabled
    ]
  }
}

struct RunnerElementTarget {
  var match: RunnerElementMatch
  var point: CGPoint
  var count: Int = 1

  /// Refuse only a control positively identified on an unrelated branch in this snapshot. An unavailable hit test
  /// or an element absent from the tree (for example a remote view) preserves the existing touch.
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
