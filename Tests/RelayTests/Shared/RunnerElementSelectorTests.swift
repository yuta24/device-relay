import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerElementSelectorTests {
  private func node(
    _ type: String, identifier: String = "", label: String = "", value: String? = nil,
    frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40), enabled: Bool = true,
    children: [RunnerElementNode] = []
  ) -> RunnerElementNode {
    RunnerElementNode(
      type: type, identifier: identifier, label: label, value: value, placeholder: nil, frame: frame,
      enabled: enabled, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children
    )
  }

  private func selector(_ json: String) throws -> RunnerElementSelector {
    try RunnerElementSelector(json: JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
  }

  private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

  /// application > window > [input, input2, button "History", other > button "History"]
  private var tree: RunnerElementNode {
    node("application", label: "Host", frame: screen, children: [
      node("window", frame: screen, children: [
        node("textField", identifier: "relay.input", value: "hello", frame: CGRect(x: 16, y: 80, width: 370, height: 34)),
        node("textField", identifier: "relay.input2", frame: CGRect(x: 16, y: 130, width: 370, height: 34)),
        node("button", label: "History", frame: CGRect(x: 20, y: 200, width: 40, height: 40)),
        node("other", children: [
          node("button", label: "History", frame: CGRect(x: 20, y: 300, width: 40, height: 40), enabled: false)
        ])
      ])
    ])
  }

  @Test func parsesSelectors() throws {
    #expect(try selector(#"{"identifier":"relay.input"}"#) == RunnerElementSelector(identifier: "relay.input"))
    #expect(try selector(#"{"label":"History","type":"button","index":1}"#)
      == RunnerElementSelector(label: "History", type: "button", index: 1))
    #expect(try selector(#"{"value":"hello","index":0}"#) == RunnerElementSelector(value: "hello", index: 0))
    #expect(try selector(#"{"type":"type83"}"#) == RunnerElementSelector(type: "type83"))
  }

  @Test func rejectsInvalidSelectors() throws {
    let cases: [(String, RunnerElementSelectorError)] = [
      (#"[]"#, .notAnObject),
      (#""relay.input""#, .notAnObject),
      (#"{}"#, .empty),
      (#"{"index":0}"#, .empty),
      (#"{"id":"relay.input"}"#, .unknownKey("id")),
      (#"{"identifier":""}"#, .notAString("identifier")),
      (#"{"label":1}"#, .notAString("label")),
      (#"{"type":"Button"}"#, .unknownType("Button")),
      (#"{"type":"type9"}"#, .unknownType("type9")),
      (#"{"type":"button","index":-1}"#, .invalidIndex),
      (#"{"type":"button","index":1.5}"#, .invalidIndex),
      (#"{"type":"button","index":true}"#, .invalidIndex),
      (#"{"type":"button","index":"1"}"#, .invalidIndex)
    ]
    for (json, expected) in cases {
      #expect(throws: expected, "\(json)") { try selector(json) }
    }
  }

  @Test func matchesExactlyWithAllConditions() {
    #expect(RunnerElementSelector(identifier: "relay.input").allMatches(in: tree).map(\.node.identifier) == ["relay.input"])
    // Exact: a prefix of the identifier or a different case doesn't match.
    #expect(RunnerElementSelector(identifier: "relay").allMatches(in: tree).isEmpty)
    #expect(RunnerElementSelector(label: "history").allMatches(in: tree).isEmpty)
    #expect(RunnerElementSelector(type: "textField", value: "hello").allMatches(in: tree).count == 1)
    #expect(RunnerElementSelector(identifier: "relay.input2", value: "hello").allMatches(in: tree).isEmpty)
    #expect(RunnerElementSelector(label: "Host", type: "application").allMatches(in: tree).count == 1)
  }

  @Test func numbersMatchesInDocumentOrder() {
    let matches = RunnerElementSelector(type: "button").allMatches(in: tree)
    #expect(matches.map(\.index) == [0, 1])
    #expect(matches.map(\.node.frame.origin.y) == [200, 300])
    #expect(matches.allSatisfy { $0.node.children.isEmpty })
    #expect(RunnerElementSelector(type: "button", index: 1).matches(in: tree).map(\.index) == [1])
    #expect(RunnerElementSelector(type: "button", index: 2).matches(in: tree).isEmpty)
    // `/find` with an index still reports every match in `count`.
    let picked = RunnerElementSelector(type: "button", index: 1)
    let all = picked.allMatches(in: tree)
    let object = RunnerElementLookup.findJSON(picked.picked(from: all), count: all.count, limit: 20, bundleID: "app")
    #expect(object["count"] as? Int == all.count)
    #expect((object["elements"] as? [[String: Any]])?.count == 1)
  }

  @Test func resolvesTheCenterOfTheFrame() throws {
    let target = try RunnerElementSelector(identifier: "relay.input2").resolve(in: tree, screen: screen).get()
    #expect(target.match.node.identifier == "relay.input2")
    #expect(target.point == CGPoint(x: 201, y: 147))
  }

  @Test func resolvesTheVisiblePartOfAFrameOnTheEdge() throws {
    let root = node("application", frame: screen, children: [
      node("cell", label: "Wi-Fi", frame: CGRect(x: 0, y: 854, width: 402, height: 44))
    ])
    let target = try RunnerElementSelector(label: "Wi-Fi").resolve(in: root, screen: screen).get()
    #expect(target.point == CGPoint(x: 201, y: 864))
  }

  /// Frames are in the displayed orientation, so a landscape screen is wider than tall.
  @Test func usesTheLandscapeScreen() throws {
    let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
    let root = node("application", frame: landscape, children: [
      node("textField", identifier: "relay.input2", frame: CGRect(x: 500, y: 100, width: 300, height: 34))
    ])
    let selector = RunnerElementSelector(identifier: "relay.input2")
    #expect(try selector.resolve(in: root, screen: landscape).get().point == CGPoint(x: 650, y: 117))
    #expect(failure(selector.resolve(in: root, screen: screen))?.reason == .offscreen)
  }

  private func failure(_ result: Result<RunnerElementTarget, RunnerElementLookupFailure>) -> RunnerElementLookupFailure? {
    guard case .failure(let failure) = result else { return nil }
    return failure
  }

  @Test func reportsMissingAndAmbiguousSelectors() throws {
    let missing = try #require(failure(RunnerElementSelector(identifier: "relay.missing").resolve(in: tree, screen: screen)))
    #expect(missing.reason == .notFound)
    #expect(missing.count == 0)
    #expect(missing.isRetryable)

    let ambiguous = try #require(failure(RunnerElementSelector(type: "textField").resolve(in: tree, screen: screen)))
    #expect(ambiguous.reason == .ambiguous)
    #expect(ambiguous.count == 2)
    #expect(ambiguous.candidates.map(\.node.identifier) == ["relay.input", "relay.input2"])
    #expect(!ambiguous.isRetryable)
    #expect(ambiguous.message == "2 elements match the selector; add conditions or an index")

    let outOfRange = try #require(failure(RunnerElementSelector(type: "textField", index: 2).resolve(in: tree, screen: screen)))
    #expect(outOfRange.reason == .indexOutOfRange)
    #expect(outOfRange.count == 2)
    #expect(outOfRange.isRetryable)
  }

  @Test func listsAtMostFiveCandidates() throws {
    let root = node("application", frame: screen, children: (0 ..< 8).map { _ in node("cell") })
    let ambiguous = try #require(failure(RunnerElementSelector(type: "cell").resolve(in: root, screen: screen)))
    #expect(ambiguous.count == 8)
    #expect((ambiguous.json["candidates"] as? [Any])?.count == 5)
  }

  @Test func rejectsElementsThatCanNotBeTouched() throws {
    let disabled = try #require(failure(RunnerElementSelector(type: "button", index: 1).resolve(in: tree, screen: screen)))
    #expect(disabled.reason == .disabled)
    #expect(disabled.count == 2)
    #expect(disabled.candidates.map(\.index) == [1])

    let root = node("application", frame: screen, children: [
      node("cell", label: "empty", frame: CGRect(x: 10, y: 10, width: 0, height: 44)),
      node("cell", label: "below", frame: CGRect(x: 0, y: 900, width: 402, height: 44)),
      node("cell", label: "touching", frame: CGRect(x: 0, y: 874, width: 402, height: 44))
    ])
    #expect(failure(RunnerElementSelector(label: "empty").resolve(in: root, screen: screen))?.reason == .emptyFrame)
    #expect(failure(RunnerElementSelector(label: "below").resolve(in: root, screen: screen))?.reason == .offscreen)
    #expect(failure(RunnerElementSelector(label: "touching").resolve(in: root, screen: screen))?.reason == .offscreen)
  }

  @Test func buildsFailureJSON() throws {
    let ambiguous = try #require(failure(RunnerElementSelector(label: "History").resolve(in: tree, screen: screen)))
    let data = try JSONSerialization.data(withJSONObject: ambiguous.json, options: [.sortedKeys])
    #expect(String(decoding: data, as: UTF8.self) == """
    {"candidates":[{"enabled":true,"frame":{"height":40,"width":40,"x":20,"y":200},"identifier":"","index":0,\
    "label":"History","type":"button","value":null},{"enabled":false,"frame":{"height":40,"width":40,"x":20,"y":300},\
    "identifier":"","index":1,"label":"History","type":"button","value":null}],"code":"element_ambiguous","count":2,\
    "error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
    """)
  }

  @Test func buildsFindJSONWithALimit() throws {
    let matches = RunnerElementSelector(type: "textField").allMatches(in: tree)
    let object = RunnerElementLookup.findJSON(matches, count: matches.count, limit: 1, bundleID: "dev.devicerelay.local.RelayRunnerHost")
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(String(decoding: data, as: UTF8.self) == """
    {"bundleId":"dev.devicerelay.local.RelayRunnerHost","count":2,"elements":[{"enabled":true,\
    "frame":{"height":34,"width":370,"x":16,"y":80},"identifier":"relay.input","index":0,"label":"",\
    "type":"textField","value":"hello"}],"ok":true,"truncated":true}
    """)
  }

  @Test func parsesTimeoutAndLimit() {
    #expect(RunnerElementLookup.timeout(nil) == 0)
    #expect(RunnerElementLookup.timeout(NSNumber(value: 2.5)) == 2.5)
    #expect(RunnerElementLookup.timeout(NSNumber(value: 10)) == 10)
    for invalid: Any in [NSNumber(value: 10.5), NSNumber(value: -1), NSNumber(value: true), "1"] {
      #expect(RunnerElementLookup.timeout(invalid) == nil, "\(invalid)")
    }
    #expect(RunnerElementLookup.findLimit(nil) == RunnerElementLookup.defaultFindLimit)
    #expect(RunnerElementLookup.findLimit(NSNumber(value: 100)) == 100)
    for invalid: Any in [NSNumber(value: 0), NSNumber(value: 101), NSNumber(value: 1.5), NSNumber(value: true), "5"] {
      #expect(RunnerElementLookup.findLimit(invalid) == nil, "\(invalid)")
    }
  }
}
