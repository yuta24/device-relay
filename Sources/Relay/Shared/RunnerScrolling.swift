import CoreGraphics
import Foundation

/// Scroll search policy and geometry shared with the CLI and its unit tests. No device calls here.
enum RunnerScrolling {
  static let defaultTimeout: TimeInterval = 20
  static let maxTimeout: TimeInterval = 60
  static let defaultSwipes = 10
  static let maxSwipes = 30
  static let moveDuration: TimeInterval = 0.5
  static let hold: TimeInterval = 0.05
  static let rest: TimeInterval = 0.15
  static let settle: TimeInterval = 0.2
  static let settleLimit: TimeInterval = 2
  static let settlePoll: TimeInterval = 0.1
  /// A last gesture may start just before the deadline; synthesis gives up 10 s after lift.
  static let lastGestureWait: TimeInterval = hold + moveDuration + rest + 10
  static let containerTypes: Set<String> = ["scrollView", "table", "collectionView", "textView"]
  static let obstructionTypes: Set<String> = ["keyboard", "navigationBar", "tabBar", "toolbar", "statusBar"]

  enum Direction: String, CaseIterable { case up, down, left, right }
  struct Invalid: Error, CustomStringConvertible {
    var description: String
    init(_ text: String) { description = "scroll: " + text }
  }
  struct Options: Equatable {
    var direction: Direction = .down
    var maxSwipes: Int = RunnerScrolling.defaultSwipes
    var timeout: TimeInterval = RunnerScrolling.defaultTimeout
    var container: RunnerElementSelector?

    init(direction: Direction = .down, maxSwipes: Int = RunnerScrolling.defaultSwipes,
         timeout: TimeInterval = RunnerScrolling.defaultTimeout, container: RunnerElementSelector? = nil) {
      self.direction = direction
      self.maxSwipes = maxSwipes
      self.timeout = timeout
      self.container = container
    }

    init(json: Any, timeout: Any?, selector: RunnerElementSelector, gone: Bool) throws {
      guard let object = json as? [String: Any] else { throw Invalid("expected an object") }
      if let key = object.keys.sorted().first(where: { !["direction", "maxSwipes", "in"].contains($0) }) {
        throw Invalid("unknown key '\(key)'")
      }
      guard selector.index == nil, !gone else { throw Invalid("cannot be combined with index or gone") }
      if let value = object["direction"] {
        guard let text = value as? String, let direction = Direction(rawValue: text) else {
          throw Invalid("direction: expected up, down, left, or right")
        }
        self.direction = direction
      }
      if let value = object["maxSwipes"] {
        guard let number = RunnerRequestValues.number(value), number.rounded() == number,
              (1 ... Double(RunnerScrolling.maxSwipes)).contains(number) else {
          throw Invalid("maxSwipes: expected an integer in 1...\(RunnerScrolling.maxSwipes)")
        }
        maxSwipes = Int(number)
      }
      if let value = timeout {
        guard let seconds = RunnerRequestValues.number(value), seconds.isFinite,
              (0 ... RunnerScrolling.maxTimeout).contains(seconds) else {
          throw Invalid("timeout: expected seconds in 0...\(Int(RunnerScrolling.maxTimeout))")
        }
        self.timeout = seconds
      }
      if let value = object["in"] {
        container = try RunnerElementSelector(json: value)
        guard container?.index == nil, container?.visibility == nil else {
          throw Invalid("in: index, onscreen, and hittable are not supported")
        }
      }
    }

    var json: [String: Any] {
      var object: [String: Any] = ["direction": direction.rawValue, "maxSwipes": maxSwipes]
      object["in"] = container?.json
      return object
    }
  }

  enum Stop: String { case found, edge, maxSwipes, timeout }
  struct Progress {
    var swipes = 0
    var stop: Stop?
    var previous: [String]?
    var unchanged = 0

    /// Ready wins even at the deadline. An edge needs two consecutive gestures with no content change.
    mutating func decision(ready: Bool, fingerprint: [String], now: TimeInterval,
                           deadline: TimeInterval, limit: Int) -> Stop? {
      if ready { stop = .found }
      else if now >= deadline { stop = .timeout }
      else {
        if swipes > 0, previous == fingerprint { unchanged += 1 } else { unchanged = 0 }
        if unchanged >= 2 { stop = .edge }
        else if swipes >= limit { stop = .maxSwipes }
      }
      previous = fingerprint
      return stop
    }
  }

  struct Container {
    var node: RunnerElementNode
    var path: [Int]
    var viewport: CGRect
    var match: RunnerElementMatch { RunnerElementMatch(index: 0, node: node, path: path) }
  }

  /// Largest visible scroll container, ties in document order. Explicit selectors must be unique.
  static func container(in root: RunnerElementNode, screen: CGRect, selector: RunnerElementSelector?) throws -> Container? {
    try selector?.checkPatternTime(in: root)
    var blockers: [CGRect] = []
    func obstacles(_ node: RunnerElementNode) {
      if obstructionTypes.contains(node.type) { blockers.append(node.frame) }
      node.children.forEach(obstacles)
    }
    obstacles(root)
    var candidates: [Container] = []
    func visit(_ node: RunnerElementNode, path: [Int], clip: CGRect) {
      let path = node.snapshotPath ?? path
      let visible = node.visibleFrame(in: clip)
      let isContainer = containerTypes.contains(node.type)
      if isContainer, node.enabled, node.positionUnknown == nil, !visible.isNull,
         selector?.matches(node) != false {
        let viewport = usable(visible, excluding: blockers)
        if viewport.width >= 44, viewport.height >= 44 {
          candidates.append(Container(node: node, path: path, viewport: viewport))
        }
      }
      for (index, child) in node.children.enumerated() {
        visit(child, path: path + [index], clip: isContainer ? visible : clip)
      }
    }
    visit(root, path: [], clip: screen)
    if selector != nil, candidates.count > 1 {
      throw RunnerElementLookupFailure(reason: .ambiguous, count: candidates.count, candidates: candidates.map(\.match))
    }
    return candidates.enumerated().max { a, b in
      let aa = a.element.viewport.width * a.element.viewport.height
      let bb = b.element.viewport.width * b.element.viewport.height
      return aa == bb ? a.offset > b.offset : aa < bb
    }?.element
  }

  /// Largest rectangular remainder, avoiding even a floating keyboard rather than swiping through it.
  static func usable(_ frame: CGRect, excluding blockers: [CGRect]) -> CGRect {
    var pieces = [frame]
    for blocker in blockers {
      pieces = pieces.flatMap { rect -> [CGRect] in
        let overlap = rect.intersection(blocker)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                CGRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
                CGRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height)]
          .filter { $0.width > 0 && $0.height > 0 }
      }
    }
    return pieces.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
  }

  static func fullyVisible(_ node: RunnerElementNode, in viewport: CGRect) -> Bool {
    guard node.touchPoint(in: viewport) != nil else { return false }
    let clip = node.clip.map(viewport.intersection) ?? viewport
    return clip.insetBy(dx: -1, dy: -1).contains(node.frame)
  }

  /// A scroll view can export placeholder frames for children of unrealized cells. Respect its
  /// ancestors' clips instead of mistaking those child frames for visible content.
  static func clipped(_ root: RunnerElementNode, to viewport: CGRect) -> RunnerElementNode {
    func visit(_ node: RunnerElementNode, clip: CGRect) -> RunnerElementNode {
      var node = node
      node.clip = node.clip.map(clip.intersection) ?? clip
      let childClip = containerTypes.contains(node.type) || node.type == "cell" || node.type == "tableRow"
        ? node.frame.intersection(node.clip!) : node.clip!
      node.children = node.children.map { visit($0, clip: childClip) }
      return node
    }
    return visit(root, clip: viewport)
  }

  struct Settlement {
    var previous: [String]?
    var equalSamples = 0
    mutating func observe(_ current: [String]) -> Bool {
      equalSamples = previous == current ? equalSamples + 1 : 0
      previous = current
      return equalSamples >= 2
    }
  }

  struct Gesture { var from: CGPoint; var to: CGPoint }
  /// Direction means where to look in the content, opposite the finger. Correct partial targets gently,
  /// even in the reverse direction after a swipe passed their leading edge.
  static func gesture(in viewport: CGRect, direction: Direction, target: CGRect? = nil) -> Gesture {
    let vertical = direction == .up || direction == .down
    let length = vertical ? viewport.height : viewport.width
    var delta = (direction == .down || direction == .right ? -1.0 : 1.0) * length * 0.65
    if let target {
      let start = vertical ? target.minY : target.minX
      let end = vertical ? target.maxY : target.maxX
      let low = vertical ? viewport.minY : viewport.minX
      let high = vertical ? viewport.maxY : viewport.maxX
      if end - start <= length - 16 {
        if start < low { delta = min(length * 0.65, max(24, low - start + 8)) }
        else if end > high { delta = max(-length * 0.65, min(-24, high - end - 8)) }
      }
    }
    let fraction = delta < 0 ? 0.85 : 0.15
    let from = CGPoint(x: vertical ? viewport.midX : viewport.minX + length * fraction,
                       y: vertical ? viewport.minY + length * fraction : viewport.midY)
    return Gesture(from: from, to: CGPoint(x: from.x + (vertical ? 0 : delta), y: from.y + (vertical ? delta : 0)))
  }

  /// Only visible content, without scroll bars or snapshot paths that change when cells are reused.
  static func fingerprint(_ root: RunnerElementNode, viewport: CGRect) -> [String] {
    var result: [String] = []
    func visit(_ node: RunnerElementNode) {
      if !containerTypes.contains(node.type), node.type != "scrollBar", node.type != "other",
         node.touchPoint(in: viewport) != nil {
        let rect = node.visibleFrame(in: viewport)
        let geometry = [rect.minX, rect.minY, rect.width, rect.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        result.append([node.type, node.identifier, node.label, node.value ?? "", geometry].joined(separator: "\u{0}"))
      }
      node.children.forEach(visit)
    }
    visit(root)
    return result
  }
}
