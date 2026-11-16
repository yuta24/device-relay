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
      (#"{"type":"button","index":"1"}"#, .invalidIndex),
      (#"{"label":"Play","onscreen":1}"#, .notABoolean("onscreen")),
      (#"{"label":"Play","hittable":"true"}"#, .notABoolean("hittable")),
      (#"{"onscreen":true}"#, .empty),
      (#"{"hittable":true,"index":0}"#, .empty)
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
    "label":"History","onscreen":true,"type":"button","value":null},{"enabled":false,"frame":{"height":40,"width":40,"x":20,"y":300},\
    "identifier":"","index":1,"label":"History","onscreen":true,"type":"button","value":null}],"code":"element_ambiguous","count":2,\
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

  @Test func verifiesTheHitIdentityForOverlappingWebControls() throws {
    // Safari / WKWebView: the label's union rectangle contains three unrelated controls.
    let root = node("application", frame: screen, children: [
      node("secureTextField", label: "Password", frame: CGRect(x: 93, y: 214, width: 155, height: 21)),
      node("button", label: "Sign in", frame: CGRect(x: 251, y: 214, width: 61, height: 21)),
      node("switch", label: "I agree", value: "0", frame: CGRect(x: 16, y: 211, width: 329, height: 46)),
      node("button", label: "Plan", frame: CGRect(x: 63, y: 237, width: 72, height: 21))
    ])
    let target = try RunnerElementSelector(label: "I agree", type: "switch").resolve(in: root, screen: screen).get()
    #expect(target.point == CGPoint(x: 180.5, y: 234))
    let rejected = try #require(failure(target.verified(hitPath: [0], in: root)))
    #expect(rejected.reason == .pointCovered)
    #expect(rejected.code == .elementPointCovered)
    #expect(rejected.json["code"] as? String == "element_point_covered")
    #expect(RunnerError.elementNotResolved(rejected).status == 422)
    #expect(rejected.isRetryable)
    #expect(!rejected.message.isEmpty)
    let hit = try #require(rejected.json["hit"] as? [String: Any])
    #expect(hit["type"] as? String == "secureTextField")
    #expect(hit["label"] as? String == "Password")
    #expect(hit["frame"] != nil)
    #expect(try target.verified(hitPath: nil, in: root).get().point == target.point)
    #expect(try target.verified(hitPath: [99], in: root).get().point == target.point)
    #expect(try target.verified(hitPath: [], in: root).get().point == target.point)
    #expect(try target.verified(hitPath: [2], in: root).get().point == target.point)
    #expect(try target.verified(hitPath: [2, 0], in: root).get().point == target.point)
    let password = try RunnerElementSelector(label: "Password").resolve(in: root, screen: screen).get()
    #expect(try password.verified(hitPath: [0], in: root).get().point == CGPoint(x: 170.5, y: 224.5))
  }

  @Test func letsSiblingLabelTextReceiveCheckboxAndRadioTouches() throws {
    // Safari iOS 27: actual one-line label frames. Radios are exposed as other, not radioButton.
    let examples: [(String, String, CGRect, CGRect, Bool)] = [
      ("Remember me", "switch", CGRect(x: 16, y: 115, width: 136, height: 22), CGRect(x: 36, y: 115, width: 116, height: 22), false),
      ("SD", "other", CGRect(x: 16, y: 154, width: 47, height: 22), CGRect(x: 36, y: 154, width: 27, height: 22), false),
      ("HD", "other", CGRect(x: 67, y: 154, width: 49, height: 22), CGRect(x: 87, y: 154, width: 29, height: 22), false),
      ("Accept terms", "switch", CGRect(x: 18, y: 193, width: 125, height: 22), CGRect(x: 40, y: 193, width: 103, height: 22), true)
    ]
    for (label, type, controlFrame, textFrame, separateLabel) in examples {
      let text = node("staticText", label: label, frame: textFrame)
      let root = node("application", frame: screen, children: [
        node(type, label: label, value: "0", frame: controlFrame),
        separateLabel ? node("other", label: label, frame: textFrame, children: [text]) : text
      ])
      let target = try RunnerElementSelector(label: label, type: type).resolve(in: root, screen: screen).get()
      let path = separateLabel ? [1, 0] : [1]
      #expect(!RunnerElementTree.isRelatedHit(path, to: target.match.path))
      #expect(try target.verified(hitPath: path, in: root).get().point == target.point, "\(label)")
    }
  }

  @Test func letsTouchesThroughNonControlContent() throws {
    for type in ["staticText", "other", "image", "group"] {
      let root = node("application", frame: screen, children: [
        node("switch", label: "Remember me", frame: CGRect(x: 16, y: 115, width: 136, height: 22)),
        node(type, label: "Label content", frame: CGRect(x: 36, y: 115, width: 116, height: 22))
      ])
      let target = try RunnerElementSelector(label: "Remember me", type: "switch").resolve(in: root, screen: screen).get()
      #expect(try target.verified(hitPath: [1], in: root).get().point == target.point, "\(type)")
    }
  }

  @Test func acceptsAStaticTextsAncestorsButRejectsASibling() throws {
    let frame = CGRect(x: 16, y: 380, width: 370, height: 52)
    let root = node("application", frame: screen, children: [
      node("window", frame: screen, children: [
        node("cell", label: "General", frame: frame, children: [
          node("staticText", label: "General", frame: CGRect(x: 30, y: 392, width: 101, height: 28))
        ]),
        node("button", label: "Overlay", frame: frame)
      ])
    ])
    let target = try RunnerElementSelector(label: "General", type: "staticText").resolve(in: root, screen: screen).get()
    #expect(target.match.path == [0, 0, 0])
    for ancestor in [[], [0], [0, 0]] {
      #expect(try target.verified(hitPath: ancestor, in: root).get().point == target.point)
    }
    let covered = try #require(failure(target.verified(hitPath: [0, 1], in: root)))
    #expect(covered.reason == .pointCovered)
    #expect(covered.hit?.label == "Overlay")
  }

  @Test func verifiesDuplicateAttributesByPathIncludingTheIndex() throws {
    let root = node("application", children: [node("button", label: "Same"), node("button", label: "Same")])
    let target = try RunnerElementSelector(label: "Same", index: 1).resolve(in: root, screen: screen).get()
    #expect(target.match.path == [1])
    #expect(failure(target.verified(hitPath: [0], in: root))?.count == 2)
    #expect(failure(target.verified(hitPath: [0], in: root))?.reason == .pointCovered)
    #expect(try target.verified(hitPath: [1], in: root).get().match.index == 1)
  }

  @Test func retainsTheOriginalIdentityAfterDisplayFiltering() throws {
    var button = node("button", label: "General")
    button.snapshotPath = [2, 0]
    let root = node("application", children: [node("window", children: [button])])
    let target = try RunnerElementSelector(label: "General").resolve(in: root, screen: screen).get()
    #expect(target.match.path == [2, 0])
    #expect(try target.verified(hitPath: [2, 0, 1], in: root).get().match.node.label == "General")
    #expect(try target.verified(hitPath: [0, 0], in: root).get().point == target.point)
  }

  @Test func ignoresAnInconsistentSafariServiceHit() throws {
    // iOS 27 SafariViewService: AX reports Address for the visible Close/Cancel button, but the
    // reported Address frame is far to its right. This is not evidence that the point is covered.
    let root = node("application", frame: screen, children: [
      node("button", identifier: "Close", label: "Cancel", frame: CGRect(x: 16, y: 78, width: 44, height: 44)),
      node("other", label: "Address", frame: CGRect(x: 167, y: 87.667, width: 67.667, height: 20.333))
    ])
    let target = try RunnerElementSelector(identifier: "Close").resolve(in: root, screen: screen).get()
    #expect(target.point == CGPoint(x: 38, y: 100))
    #expect(RunnerElementTree.hitControl(at: target.point, path: [1], in: root) == nil)
    #expect(try target.verified(hitPath: [1], in: root).get().point == target.point)
    #expect(RunnerElementTree.hitControl(at: target.point, path: [99], in: root) == nil)
    var control = root
    control.children[1].type = "button"
    #expect(try target.verified(hitPath: [1], in: control).get().point == target.point)
  }

  @Test func parsesGone() throws {
    let selector = RunnerElementSelector(identifier: "spinner")
    #expect(try RunnerElementLookup.gone(nil, selector: selector).get() == false)
    #expect(try RunnerElementLookup.gone(NSNumber(value: true), selector: selector).get() == true)
    #expect(try RunnerElementLookup.gone(NSNumber(value: false), selector: selector).get() == false)
    for invalid: Any in [NSNumber(value: 1), "true", NSNull()] {
      #expect(throws: RunnerFindGoneError.notABoolean, "\(invalid)") { try RunnerElementLookup.gone(invalid, selector: selector).get() }
    }
    // An index picks a different element as the others go, so it can't be waited out.
    let indexed = RunnerElementSelector(type: "cell", index: 1)
    #expect(throws: RunnerFindGoneError.withIndex) { try RunnerElementLookup.gone(NSNumber(value: true), selector: indexed).get() }
    #expect(try RunnerElementLookup.gone(NSNumber(value: false), selector: indexed).get() == false)
    #expect(RunnerFindGoneError.withIndex.description.contains("element.index"))
  }

  @Test func findStopsWhenWhatItWaitsForHappens() {
    // Waiting for an element: done once one matches.
    #expect(RunnerElementLookup.findIsDone(matchCount: 0, gone: false, isLastAttempt: false) == false)
    #expect(RunnerElementLookup.findIsDone(matchCount: 2, gone: false, isLastAttempt: false))
    // Waiting for it to go: done once none does.
    #expect(RunnerElementLookup.findIsDone(matchCount: 0, gone: true, isLastAttempt: false))
    #expect(RunnerElementLookup.findIsDone(matchCount: 1, gone: true, isLastAttempt: false) == false)
    // The last attempt answers with what it found either way.
    #expect(RunnerElementLookup.findIsDone(matchCount: 0, gone: false, isLastAttempt: true))
    #expect(RunnerElementLookup.findIsDone(matchCount: 1, gone: true, isLastAttempt: true))
  }

  @Test func saysWhetherTheElementWentOnlyWhenAsked() throws {
    let all = RunnerElementSelector(label: "History").allMatches(in: tree)
    #expect(RunnerElementLookup.findJSON(all, count: 2, limit: 20, bundleID: "app")["gone"] == nil)
    #expect(RunnerElementLookup.findJSON(all, count: 2, limit: 20, bundleID: "app", gone: true)["gone"] as? Bool == false)
    #expect(RunnerElementLookup.findJSON([], count: 0, limit: 20, bundleID: "app", gone: true)["gone"] as? Bool == true)
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

  // MARK: - onscreen and hittable

  @Test func parsesVisibility() throws {
    #expect(try selector(#"{"label":"Play","onscreen":true}"#) == RunnerElementSelector(label: "Play", visibility: .onscreen))
    #expect(try selector(#"{"label":"Play","hittable":true}"#) == RunnerElementSelector(label: "Play", visibility: .hittable))
    // hittable is on the screen too, so both together are hittable; false is the same as absent.
    #expect(try selector(#"{"label":"Play","onscreen":true,"hittable":true}"#).visibility == .hittable)
    #expect(try selector(#"{"label":"Play","onscreen":true,"hittable":false}"#).visibility == .onscreen)
    #expect(try selector(#"{"label":"Play","onscreen":false}"#).visibility == nil)
    // What relay sends parses back to the same selector, and a selector without them sends neither key.
    let hittable = RunnerElementSelector(label: "Play", index: 1, visibility: .hittable)
    #expect(try RunnerElementSelector(json: hittable.json) == hittable)
    #expect(hittable.json["hittable"] as? Bool == true && hittable.json["onscreen"] == nil)
    #expect(RunnerElementSelector(label: "Play", visibility: .onscreen).json["onscreen"] as? Bool == true)
    #expect(RunnerElementSelector(label: "Play").json.keys.sorted() == ["label"])
    // The unknown key error, which is how a runner from before them answers, names them now.
    #expect(RunnerElementSelectorError.unknownKey("id").description.hasSuffix("index, onscreen, hittable)"))
  }

  /// application > window > three pages side by side, each with `Page title`; only the first is on the screen.
  private var pages: RunnerElementNode {
    node("application", frame: screen, children: [
      node("window", frame: screen, children: (0 ..< 3).map { page in
        node("other", frame: CGRect(x: CGFloat(page) * 402, y: 200, width: 402, height: 100), children: [
          node("staticText", identifier: "page\(page + 1)", label: "Page title",
               frame: CGRect(x: CGFloat(page) * 402 + 160, y: 230, width: 80, height: 30))
        ])
      })
    ])
  }

  @Test func saysWhetherEachMatchIsOnTheScreen() throws {
    let all = RunnerElementSelector(label: "Page title").allMatches(in: pages, screen: screen)
    #expect(all.map(\.onscreen) == [true, false, false])
    #expect(all.map(\.index) == [0, 1, 2])
    #expect(all[1].json["onscreen"] as? Bool == false)
    // Without the screen (frames that can't be placed on it), nothing is said, and the JSON has no key.
    let unplaced = RunnerElementSelector(label: "Page title").allMatches(in: pages)
    #expect(unplaced.allSatisfy { $0.onscreen == nil } && unplaced[0].json["onscreen"] == nil)
    #expect(RunnerElementSelector(label: "Page title", visibility: .onscreen).allMatches(in: pages).isEmpty)
  }

  @Test func onscreenKeepsTheMatchesOnTheScreenAndNumbersThem() throws {
    var root = pages
    // Scrolled to the second page: the first is off to the left.
    root.children[0].children = root.children[0].children.map { page in
      var page = page
      page.frame.origin.x -= 402
      page.children[0].frame.origin.x -= 402
      return page
    }
    let onscreen = RunnerElementSelector(label: "Page title", visibility: .onscreen)
    let kept = onscreen.allMatches(in: root, screen: screen)
    #expect(kept.map(\.node.identifier) == ["page2"])
    #expect(kept.map(\.index) == [0])
    #expect(kept[0].onscreen == true)
    // index counts the kept matches only: 0 is the page on the screen, 1 is out of range.
    #expect(RunnerElementSelector(label: "Page title", index: 0, visibility: .onscreen).matches(in: root, screen: screen)
      .map(\.node.identifier) == ["page2"])
    #expect(RunnerElementSelector(label: "Page title", index: 1, visibility: .onscreen).matches(in: root, screen: screen).isEmpty)
    // A touch picks the only one on the screen, where without onscreen the selector is ambiguous.
    #expect(try onscreen.resolve(in: root, screen: screen).get().match.node.identifier == "page2")
    #expect(failure(RunnerElementSelector(label: "Page title").resolve(in: root, screen: screen))?.reason == .ambiguous)
    let outOfRange = try #require(failure(
      RunnerElementSelector(label: "Page title", index: 1, visibility: .onscreen).resolve(in: root, screen: screen)
    ))
    #expect(outOfRange.reason == .indexOutOfRange && outOfRange.count == 1)
    // find reports the kept matches: count, limit, and truncated all after the filter.
    let object = RunnerElementLookup.findJSON(kept, count: kept.count, limit: 20, bundleID: "app")
    #expect(object["count"] as? Int == 1 && object["truncated"] as? Bool == false)
  }

  @Test func elementsThatCannotBePlacedAreNotOnTheScreen() throws {
    var root = pages
    root.children[0].children[0].children[0].positionUnknown = "the share sheet is laid out unexpectedly"
    root.children[0].children[1].children[0].frame = CGRect(x: 100, y: 230, width: 0, height: 30)
    let all = RunnerElementSelector(label: "Page title").allMatches(in: root, screen: screen)
    #expect(all.map(\.onscreen) == [false, false, false])
    #expect(RunnerElementSelector(label: "Page title", visibility: .onscreen).allMatches(in: root, screen: screen).isEmpty)
  }

  /// application > window > [screen: other > [button Play > staticText, staticText Now playing],
  /// player: other > button Play > staticText] — the player covers the whole screen.
  private var player: RunnerElementNode {
    let play = CGRect(x: 16, y: 150, width: 370, height: 34)
    return node("application", frame: screen, children: [
      node("window", frame: screen, children: [
        node("other", frame: screen, children: [
          node("button", identifier: "screen.play", label: "Play", frame: play, children: [
            node("staticText", label: "Play", frame: CGRect(x: 185, y: 157, width: 32, height: 20))
          ]),
          node("staticText", identifier: "screen.nowPlaying", label: "Now playing", frame: CGRect(x: 16, y: 120, width: 100, height: 20))
        ]),
        node("other", frame: screen, children: [
          node("button", identifier: "player.play", label: "Play", frame: CGRect(x: 16, y: 300, width: 60, height: 34), children: [
            node("staticText", label: "Play", frame: CGRect(x: 30, y: 307, width: 32, height: 20))
          ])
        ])
      ])
    ])
  }

  /// What the player's hit test answers, as measured on a simulator: a touch on the player's button reaches its text,
  /// and one on anything of the screen under it reaches the player's container.
  private final class Calls { var count = 0 }

  private func playerHitTest(calls: Calls? = nil) -> RunnerElementSelector.HitTest {
    { point in
      calls?.count += 1
      return CGRect(x: 16, y: 300, width: 60, height: 34).contains(point) ? [0, 1, 0, 0] : [0, 1]
    }
  }

  @Test func hittableKeepsWhatATouchReaches() throws {
    let hittable = RunnerElementSelector(label: "Play", visibility: .hittable)
    let all = RunnerElementSelector(label: "Play").allMatches(in: player, screen: screen)
    #expect(all.count == 4 && all.allSatisfy { $0.onscreen == true })
    let kept = hittable.allMatches(in: player, screen: screen, hitTest: playerHitTest())
    // The player's button (the hit is inside it) and its text (the hit), in document order, numbered from 0.
    #expect(kept.map(\.path) == [[0, 1, 0], [0, 1, 0, 0]])
    #expect(kept.map(\.index) == [0, 1])
    #expect(RunnerElementSelector(label: "Now playing", visibility: .hittable)
      .allMatches(in: player, screen: screen, hitTest: playerHitTest()).isEmpty)
    // tap --label Play --type button --hittable touches the player's, which without hittable is ambiguous.
    let button = RunnerElementSelector(label: "Play", type: "button", visibility: .hittable)
    let target = try button.resolve(in: player, screen: screen, hitTest: playerHitTest()).get()
    #expect(target.match.node.identifier == "player.play" && target.count == 1)
    #expect(failure(RunnerElementSelector(label: "Play", type: "button").resolve(in: player, screen: screen))?.reason == .ambiguous)
    // index n of find --hittable is the element tap --hittable --index n touches.
    for match in kept {
      let picked = RunnerElementSelector(label: "Play", index: match.index, visibility: .hittable)
      #expect(try picked.resolve(in: player, screen: screen, hitTest: playerHitTest()).get().match.path == match.path)
    }
  }

  @Test func hittableTestsOnlyMatchesOnTheScreenAndNeedsAHitTest() throws {
    let calls = Calls()
    let selector = RunnerElementSelector(label: "Page title", visibility: .hittable)
    let kept = selector.allMatches(in: pages, screen: screen, hitTest: playerHitTest(calls: calls))
    #expect(calls.count == 1 && kept.isEmpty)
    // Without a hit test (the runner checks it can answer first), nothing can be shown to be reachable.
    #expect(RunnerElementSelector(label: "Play", visibility: .hittable).allMatches(in: player, screen: screen).isEmpty)
    // No answer at a point is not a reach either.
    #expect(RunnerElementSelector(label: "Play", visibility: .hittable).allMatches(in: player, screen: screen) { _ in nil }.isEmpty)
  }

  @Test func reachesTheElementItsContentsOrAContainingControl() {
    let root = node("application", frame: screen, children: [
      node("window", frame: screen, children: [
        node("cell", frame: CGRect(x: 0, y: 100, width: 402, height: 44), children: [
          node("staticText", label: "General", frame: CGRect(x: 16, y: 110, width: 80, height: 20))
        ]),
        node("staticText", label: "Footer", frame: CGRect(x: 16, y: 300, width: 80, height: 20))
      ])
    ])
    let point = CGPoint(x: 56, y: 120)
    let text = [0, 0, 0]
    #expect(RunnerElementTree.reaches(hitPath: text, target: text, at: point, in: root))
    #expect(RunnerElementTree.reaches(hitPath: text, target: [0, 0], at: point, in: root))
    // The cell around the text gets the touch.
    #expect(RunnerElementTree.reaches(hitPath: [0, 0], target: text, at: point, in: root))
    // A container that isn't a control (the window, an other over the screen) doesn't show the touch gets there.
    #expect(!RunnerElementTree.reaches(hitPath: [0], target: text, at: point, in: root))
    #expect(!RunnerElementTree.reaches(hitPath: [], target: text, at: point, in: root))
    // Another branch, or no answer.
    #expect(!RunnerElementTree.reaches(hitPath: [0, 1], target: text, at: point, in: root))
    #expect(!RunnerElementTree.reaches(hitPath: nil, target: text, at: point, in: root))
    // A containing control whose frame doesn't hold the point is no proof.
    #expect(!RunnerElementTree.reaches(hitPath: [0, 0], target: text, at: CGPoint(x: 56, y: 300), in: root))
  }

  @Test func failsHittableWhereHitTestingCannotAnswer() throws {
    let placed = RunnerWindowLookup.placed(RunnerWindowPlacement(
      frame: CGRect(x: 120, y: 80, width: 600, height: 800), scaleX: 1, scaleY: 1
    ))
    #expect(RunnerElementTree.hitTestUnavailableMessage(window: nil, displayCount: 1, apiUnavailable: nil) == nil)
    #expect(RunnerElementTree.hitTestUnavailableMessage(window: .fullScreen, displayCount: 0, apiUnavailable: nil) == nil)
    let multiple = try #require(RunnerElementTree.hitTestUnavailableMessage(window: nil, displayCount: 2, apiUnavailable: nil))
    #expect(multiple.contains("more than one display") && multiple.contains("Use onscreen instead"))
    let windowed = try #require(RunnerElementTree.hitTestUnavailableMessage(window: placed, displayCount: 1, apiUnavailable: nil))
    #expect(windowed.contains("not full screen"))
    let disabled = try #require(RunnerElementTree.hitTestUnavailableMessage(window: nil, displayCount: 1, apiUnavailable: "turned off"))
    #expect(disabled.contains("(turned off)"))
    let error = RunnerError.hitTestUnavailable(disabled)
    #expect(error.status == 422 && error.code == .hitTestUnavailable && error.json["code"] as? String == "hit_test_unavailable")
    #expect(RunnerWindows.visibilityError("cannot tell").contains("onscreen and hittable cannot be checked"))
  }

  // MARK: - labelMatch and valueMatch

  private func pattern(_ source: String) throws -> RunnerElementPattern { try RunnerElementPattern(source) }

  @Test func parsesPatterns() throws {
    #expect(try selector(#"{"labelMatch":"^Remaining"}"#) == RunnerElementSelector(labelMatch: try pattern("^Remaining")))
    #expect(try selector(#"{"valueMatch":"^$","type":"textField","index":1}"#)
      == RunnerElementSelector(type: "textField", valueMatch: try pattern("^$"), index: 1))
    // An exact match on one attribute and a pattern on the other is fine; what relay sends parses back to the same.
    let both = RunnerElementSelector(label: "Play", valueMatch: try pattern("(?i)on"), visibility: .hittable)
    #expect(try RunnerElementSelector(json: both.json) == both)
    #expect(both.json["valueMatch"] as? String == "(?i)on" && both.json["labelMatch"] == nil)
    #expect(RunnerElementSelector(labelMatch: try pattern("a")) != RunnerElementSelector(labelMatch: try pattern("b")))
  }

  @Test func rejectsInvalidPatterns() throws {
    let cases: [(String, RunnerElementSelectorError)] = [
      (#"{"labelMatch":"("}"#, .invalidPattern("labelMatch")),
      (#"{"valueMatch":"[a"}"#, .invalidPattern("valueMatch")),
      (#"{"labelMatch":"a{2,1}"}"#, .invalidPattern("labelMatch")),
      (#"{"labelMatch":""}"#, .notAString("labelMatch")),
      (#"{"valueMatch":1}"#, .notAString("valueMatch")),
      (#"{"label":"Play","labelMatch":"Play"}"#, .exactAndPattern("label", "labelMatch")),
      (#"{"value":"on","valueMatch":"on"}"#, .exactAndPattern("value", "valueMatch")),
      ("{\"labelMatch\":\"\(String(repeating: "a", count: RunnerElementPattern.maxLength + 1))\"}", .patternTooLong("labelMatch"))
    ]
    for (json, expected) in cases {
      #expect(throws: expected, "\(json.prefix(60))") { try selector(json) }
    }
    #expect(try selector("{\"labelMatch\":\"\(String(repeating: "a", count: RunnerElementPattern.maxLength))\"}").labelMatch != nil)
    #expect(RunnerElementSelectorError.exactAndPattern("label", "labelMatch").description
      == "element: label and labelMatch cannot be combined (label matches exactly; write ^...$ in labelMatch for that)")
    #expect(RunnerElementSelectorError.unknownKey("id").description.contains("labelMatch, valueMatch"))
    #expect(RunnerElementSelectorError.empty.description.hasSuffix("value, labelMatch, valueMatch"))
  }

  /// A label with a count and a time in it, one with a line break, and a value that is empty or absent.
  private var changing: RunnerElementNode {
    node("application", frame: screen, children: [
      node("window", frame: screen, children: [
        node("button", identifier: "countdown", label: "Remaining 3:42", value: "taps: 2", frame: CGRect(x: 16, y: 80, width: 200, height: 34)),
        node("staticText", identifier: "count", label: "12 items", frame: CGRect(x: 16, y: 130, width: 200, height: 20)),
        node("staticText", identifier: "lines", label: "First line\nSecond line", frame: CGRect(x: 16, y: 160, width: 200, height: 40)),
        node("textField", identifier: "empty", value: "", frame: CGRect(x: 16, y: 210, width: 200, height: 34)),
        node("button", identifier: "play", label: "PLAY", frame: CGRect(x: 16, y: 260, width: 200, height: 34))
      ])
    ])
  }

  private func ids(_ selector: RunnerElementSelector, in root: RunnerElementNode? = nil) -> [String] {
    selector.allMatches(in: root ?? changing, screen: screen).map(\.node.identifier)
  }

  @Test func patternsMatchAnywhereUnlessAnchored() throws {
    #expect(ids(RunnerElementSelector(labelMatch: try pattern(#"Remaining \d+:\d{2}"#))) == ["countdown"])
    #expect(ids(RunnerElementSelector(labelMatch: try pattern(#"^\d+ items$"#))) == ["count"])
    // Somewhere in the label: "line" is in one label only, "i" in four.
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("line"))) == ["lines"])
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("i"))) == ["countdown", "count", "lines"])
    // ^ and $ match the whole label: "Remaining" alone is not it.
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^Remaining$"))).isEmpty)
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^Remaining"))) == ["countdown"])
    // Case matters unless the pattern says (?i).
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^Play$"))).isEmpty)
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("(?i)^play$"))) == ["play"])
    // Combined with the other attributes by AND.
    #expect(ids(RunnerElementSelector(type: "staticText", labelMatch: try pattern("^\\d"))) == ["count"])
    #expect(ids(RunnerElementSelector(type: "button", labelMatch: try pattern("^\\d"))).isEmpty)
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^Remaining"), valueMatch: try pattern(#"^taps: \d+$"#))) == ["countdown"])
  }

  @Test func patternsOverLineBreaks() throws {
    // Without options . stops at a line break and ^ $ are the ends of the whole label; (?s) and (?m) change that.
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("First.*Second"))).isEmpty)
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("(?s)First.*Second"))) == ["lines"])
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^Second line$"))).isEmpty)
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("(?m)^Second line$"))) == ["lines"])
    #expect(ids(RunnerElementSelector(labelMatch: try pattern("^First line\nSecond line$"))) == ["lines"])
  }

  @Test func anAbsentValueIsEmpty() throws {
    // ^$ picks the elements whose value is empty or absent (null in /source), as --format compact shows both.
    #expect(ids(RunnerElementSelector(type: "textField", valueMatch: try pattern("^$"))) == ["empty"])
    #expect(ids(RunnerElementSelector(valueMatch: try pattern("^$"))) == ["", "", "count", "lines", "empty", "play"])
    // .+ picks the ones with a value; an empty label is the empty string too.
    #expect(ids(RunnerElementSelector(valueMatch: try pattern(".+"))) == ["countdown"])
    #expect(ids(RunnerElementSelector(type: "textField", labelMatch: try pattern("^$"))) == ["empty"])
  }

  @Test func patternsWithVisibilityAndIndex() throws {
    // Of the four Play labels, (?i)^play$ with hittable keeps the player's button and its text, as --label Play does.
    let hittable = RunnerElementSelector(labelMatch: try pattern("(?i)^play$"), visibility: .hittable)
    let kept = hittable.allMatches(in: player, screen: screen, hitTest: playerHitTest())
    #expect(kept.map(\.path) == RunnerElementSelector(label: "Play", visibility: .hittable)
      .allMatches(in: player, screen: screen, hitTest: playerHitTest()).map(\.path))
    let button = RunnerElementSelector(type: "button", labelMatch: try pattern("^Pl"), visibility: .hittable)
    #expect(try button.resolve(in: player, screen: screen, hitTest: playerHitTest()).get().match.node.identifier == "player.play")
    // onscreen and index count only the kept ones.
    let onscreen = RunnerElementSelector(labelMatch: try pattern("title$"), visibility: .onscreen)
    #expect(onscreen.allMatches(in: pages, screen: screen).map(\.node.identifier) == ["page1"])
    #expect(RunnerElementSelector(labelMatch: try pattern("title$"), index: 2).matches(in: pages, screen: screen)
      .map(\.node.identifier) == ["page3"])
  }

  @Test func lookupFailuresAreTheSameWithPatterns() throws {
    let ambiguous = RunnerElementSelector(labelMatch: try pattern("^Page"))
    guard case .failure(let failure) = ambiguous.resolve(in: pages, screen: screen) else {
      Issue.record("expected element_ambiguous")
      return
    }
    #expect(failure.code == .elementAmbiguous && failure.count == 3 && failure.candidates.count == 3)
    #expect(failure.json["candidates"].map { ($0 as? [[String: Any]])?.map { $0["label"] as? String } } == ["Page title", "Page title", "Page title"])
    guard case .failure(let missing) = RunnerElementSelector(labelMatch: try pattern("^Nothing")).resolve(in: pages, screen: screen) else {
      Issue.record("expected element_not_found")
      return
    }
    #expect(missing.code == .elementNotFound && missing.reason == .notFound && missing.isRetryable)
  }

  @Test func aPatternThatBacktracksTooLongFails() throws {
    let slow = RunnerElementSelector(labelMatch: try pattern("(a+)+$"))
    var root = changing
    root.children[0].children.append(node("staticText", label: String(repeating: "a", count: 40) + "b"))
    let started = Date()
    #expect(throws: RunnerElementSelectorError.patternTooSlow("labelMatch")) { try slow.checkPatternTime(in: root, budget: 0.2) }
    #expect(Date().timeIntervalSince(started) < 2)
    // An ordinary pattern, and a selector without one, pass.
    try RunnerElementSelector(labelMatch: try pattern("^Remaining"), valueMatch: try pattern("taps")).checkPatternTime(in: root)
    try RunnerElementSelector(label: "Play").checkPatternTime(in: root, budget: 0)
    #expect(RunnerElementSelectorError.patternTooSlow("valueMatch").description.hasPrefix("element.valueMatch: the regular expression took"))
    #expect(try pattern("a").matches("bab", before: .distantFuture) == true)
    #expect(try pattern("c").matches("bab", before: .distantFuture) == false)
  }

  @Test func patternsOverAHundredElementsAreFast() throws {
    // The relay.visibility grid: 100 texts. Exact and pattern matching both take well under the poll interval.
    let grid = node("application", frame: screen, children: [node("window", frame: screen, children: (1 ... 100).map {
      node("staticText", identifier: "relay.item\($0)", label: "Item", frame: CGRect(x: 0, y: CGFloat($0) * 4, width: 40, height: 4))
    })])
    let selector = RunnerElementSelector(labelMatch: try pattern(#"^Item$"#))
    let started = Date()
    for _ in 0 ..< 100 {
      try selector.checkPatternTime(in: grid)
      #expect(selector.allMatches(in: grid, screen: screen).count == 100)
    }
    #expect(Date().timeIntervalSince(started) / 100 < RunnerElementLookup.pollInterval)
  }
}
