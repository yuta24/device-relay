import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerScrollingTests {
  private let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
  private func node(_ type: String = "table", id: String = "", frame: CGRect = CGRect(x: 0, y: 100, width: 400, height: 600),
                    children: [RunnerElementNode] = []) -> RunnerElementNode {
    RunnerElementNode(type: type, identifier: id, label: id, value: nil, placeholder: nil, frame: frame,
                      enabled: true, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children)
  }
  private func options(_ object: Any, timeout: Any? = nil, index: Int? = nil, gone: Bool = false) throws -> RunnerScrolling.Options {
    try RunnerScrolling.Options(json: object, timeout: timeout, selector: RunnerElementSelector(identifier: "row", index: index), gone: gone)
  }

  @Test func parsesDefaultsAndRejectsInvalidSearchesBeforeInput() throws {
    #expect(try options([:]) == RunnerScrolling.Options())
    #expect(try options(["direction": "left", "maxSwipes": 30], timeout: 60).direction == .left)
    #expect(try options([:], timeout: 0).timeout == 0)
    #expect(try options(["in": ["identifier": "list"]]).container?.identifier == "list")
    let invalid: [Any] = [true, NSNull(), ["direction": "diagonal"], ["direction": true],
                          ["maxSwipes": 0], ["maxSwipes": 31], ["maxSwipes": 1.5], ["maxSwipes": true],
                          ["oops": 1], ["in": "list"], ["in": ["identifier": "list", "index": 0]],
                          ["in": ["identifier": "list", "hittable": true]]]
    for value in invalid { #expect(throws: (any Error).self) { try options(value) } }
    for timeout in [-1, 61, true, "20", Double.infinity] as [Any] {
      #expect(throws: (any Error).self) { try options([:], timeout: timeout) }
    }
    #expect(throws: (any Error).self) { try options([:], index: 0) }
    #expect(throws: (any Error).self) { try options([:], gone: true) }
  }

  @Test func selectsLargestAndExplicitContainersClippedToParentsAndChrome() throws {
    let small = node(id: "small", frame: CGRect(x: 0, y: 200, width: 100, height: 300))
    let large = node(id: "large", children: [small])
    let keyboard = node("keyboard", frame: CGRect(x: 0, y: 500, width: 400, height: 300))
    let root = node("application", frame: screen, children: [large, keyboard])
    #expect(try RunnerScrolling.container(in: root, screen: screen, selector: nil)?.node.identifier == "large")
    #expect(try RunnerScrolling.container(in: root, screen: screen, selector: nil)?.viewport == CGRect(x: 0, y: 100, width: 400, height: 400))
    #expect(try RunnerScrolling.container(in: root, screen: screen, selector: RunnerElementSelector(identifier: "small"))?.path == [0, 0])
    #expect(try RunnerScrolling.container(in: root, screen: screen, selector: RunnerElementSelector(identifier: "absent")) == nil)
    #expect(throws: RunnerElementLookupFailure.self) {
      try RunnerScrolling.container(in: root, screen: screen, selector: RunnerElementSelector(type: "table"))
    }
    let tie = node("application", children: [small, small])
    #expect(try RunnerScrolling.container(in: tie, screen: screen, selector: nil)?.path == [0])
    var disabled = large; disabled.enabled = false
    #expect(try RunnerScrolling.container(in: disabled, screen: screen, selector: nil)?.node.identifier == "small")
    var unknown = small; unknown.positionUnknown = "remote"
    #expect(try RunnerScrolling.container(in: unknown, screen: screen, selector: nil) == nil)
  }

  @Test func avoidsBarsAndFloatingKeyboardsAndRejectsPartialFrames() {
    let viewport = RunnerScrolling.usable(screen, excluding: [CGRect(x: 0, y: 0, width: 400, height: 100),
                                                              CGRect(x: 0, y: 700, width: 400, height: 100)])
    #expect(viewport == CGRect(x: 0, y: 100, width: 400, height: 600))
    let floating = CGRect(x: 200, y: 300, width: 200, height: 300)
    #expect(!RunnerScrolling.usable(screen, excluding: [floating]).intersects(floating))
    #expect(RunnerScrolling.usable(screen, excluding: [screen]) == .zero)
    #expect(RunnerScrolling.fullyVisible(node(frame: viewport), in: viewport))
    #expect(!RunnerScrolling.fullyVisible(node(frame: viewport.offsetBy(dx: 0, dy: 20)), in: viewport))
    var clipped = node(frame: viewport); clipped.clip = CGRect(x: 0, y: 200, width: 400, height: 500)
    #expect(!RunnerScrolling.fullyVisible(clipped, in: viewport))
    #expect(!RunnerScrolling.fullyVisible(node(frame: .zero), in: viewport))
  }

  @Test func directionsAndPartialCorrectionsStayInTheViewport() {
    for direction in RunnerScrolling.Direction.allCases {
      let gesture = RunnerScrolling.gesture(in: screen, direction: direction)
      #expect(screen.contains(gesture.from) && screen.contains(gesture.to))
      switch direction {
      case .down: #expect(gesture.to.y < gesture.from.y)
      case .up: #expect(gesture.to.y > gesture.from.y)
      case .right: #expect(gesture.to.x < gesture.from.x)
      case .left: #expect(gesture.to.x > gesture.from.x)
      }
    }
    let top = RunnerScrolling.gesture(in: screen, direction: .down, target: CGRect(x: 10, y: -20, width: 100, height: 40))
    #expect(top.to.y > top.from.y)
    let bottom = RunnerScrolling.gesture(in: screen, direction: .down, target: CGRect(x: 10, y: 780, width: 100, height: 40))
    #expect(bottom.from.y - bottom.to.y == 28)
    let tiny = RunnerScrolling.gesture(in: screen, direction: .down, target: CGRect(x: 10, y: 761, width: 100, height: 40))
    #expect(tiny.from.y - tiny.to.y == 24)
    let left = RunnerScrolling.gesture(in: screen, direction: .right, target: CGRect(x: -20, y: 10, width: 40, height: 40))
    #expect(left.to.x > left.from.x)
    let right = RunnerScrolling.gesture(in: screen, direction: .right, target: CGRect(x: 380, y: 10, width: 40, height: 40))
    #expect(right.to.x < right.from.x)
  }

  @Test func stopsAtReadyDeadlineLimitOrTwoUnchangedSwipes() {
    var state = RunnerScrolling.Progress()
    #expect(state.decision(ready: false, fingerprint: ["a"], now: 0, deadline: 20, limit: 10) == nil)
    state.swipes = 1
    #expect(state.decision(ready: false, fingerprint: ["a"], now: 1, deadline: 20, limit: 10) == nil)
    state.swipes = 2
    #expect(state.decision(ready: false, fingerprint: ["b"], now: 2, deadline: 20, limit: 10) == nil)
    state.swipes = 3
    #expect(state.decision(ready: false, fingerprint: ["b"], now: 3, deadline: 20, limit: 10) == nil)
    state.swipes = 4
    #expect(state.decision(ready: false, fingerprint: ["b"], now: 4, deadline: 20, limit: 10) == .edge)
    var timeout = RunnerScrolling.Progress()
    #expect(timeout.decision(ready: false, fingerprint: [], now: 20, deadline: 20, limit: 10) == .timeout)
    var found = RunnerScrolling.Progress()
    #expect(found.decision(ready: true, fingerprint: [], now: 20, deadline: 20, limit: 10) == .found)
    var limit = RunnerScrolling.Progress(); limit.swipes = 1
    #expect(limit.decision(ready: false, fingerprint: [], now: 1, deadline: 20, limit: 1) == .maxSwipes)
  }

  @Test func fingerprintTracksVisibleContentButNotScrollbarNoise() {
    let cell = node("cell", id: "row1", frame: CGRect(x: 0, y: 100, width: 400, height: 44))
    var root = node(children: [cell, node("scrollBar", id: "thumb")])
    let original = RunnerScrolling.fingerprint(root, viewport: screen)
    root.children[1].label = "moved thumb"
    #expect(RunnerScrolling.fingerprint(root, viewport: screen) == original)
    root.children[0].identifier = "row2"
    #expect(RunnerScrolling.fingerprint(root, viewport: screen) != original)
  }
}

extension RunnerScrollingTests {
  @Test func ignoresPlaceholderChildrenOfOffscreenCellsAndWaitsForTwoEqualSamples() {
    let fake = node("staticText", id: "Row42", frame: CGRect(x: 0, y: 100, width: 300, height: 44))
    let row = node("cell", id: "cell42", frame: CGRect(x: 0, y: 2000, width: 400, height: 44), children: [fake])
    let tree = node(children: [row])
    let clipped = RunnerScrolling.clipped(tree, to: screen)
    let selector = RunnerElementSelector(identifier: "Row42", visibility: .onscreen)
    #expect(selector.allMatches(in: tree, screen: screen).count == 1)
    #expect(selector.allMatches(in: clipped, screen: screen).isEmpty)
    #expect(RunnerScrolling.fingerprint(clipped, viewport: screen).isEmpty)
    var settlement = RunnerScrolling.Settlement()
    let observe: ([String]) -> Bool = { settlement.observe($0) }
    #expect(!observe(["moving1"]))
    #expect(!observe(["moving2"]))
    #expect(!observe(["stopped"]))
    #expect(!observe(["stopped"]))
    #expect(observe(["stopped"]))
    #expect(!observe(["moving again"]))
  }
}
