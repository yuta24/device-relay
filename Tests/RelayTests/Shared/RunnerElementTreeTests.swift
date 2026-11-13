import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerElementTreeTests {
  @Test func verifiesHitsOnlyInCheckedCoordinateSpaces() {
    let placed = RunnerWindowLookup.placed(RunnerWindowPlacement(
      frame: CGRect(x: 120, y: 80, width: 600, height: 800), scaleX: 1, scaleY: 1
    ))
    for count in [0, 1] {
      #expect(RunnerElementTree.canVerifyHit(window: nil, displayCount: count))
      #expect(RunnerElementTree.canVerifyHit(window: .fullScreen, displayCount: count))
      #expect(!RunnerElementTree.canVerifyHit(window: placed, displayCount: count))
      #expect(!RunnerElementTree.canVerifyHit(window: .unknown("no window position"), displayCount: count))
    }
    for window in [nil, .fullScreen, placed, .unknown("no window position")] as [RunnerWindowLookup?] {
      #expect(!RunnerElementTree.canVerifyHit(window: window, displayCount: 2))
      #expect(!RunnerElementTree.canVerifyHit(window: window, displayCount: 3))
    }
  }

  private func node(_ type: String, children: [RunnerElementNode] = [], truncated: Bool = false) -> RunnerElementNode {
    RunnerElementNode(
      type: type, identifier: "", label: "", value: nil, placeholder: nil, frame: .zero,
      enabled: true, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children,
      truncated: truncated
    )
  }

  /// Two snapshots of one picker wheel gave 215 and 215.00000000000006 for its height.
  @Test func sameFrameAllowsAHundredthOfAPoint() {
    let frame = CGRect(x: 25, y: 484.833, width: 173, height: 215)
    #expect(RunnerElementTree.sameFrame(frame, CGRect(x: 25, y: 484.833, width: 173, height: 215.00000000000006)))
    #expect(RunnerElementTree.sameFrame(frame, CGRect(x: 25.005, y: 484.83, width: 173, height: 215)))
    #expect(!RunnerElementTree.sameFrame(frame, CGRect(x: 25, y: 484.833, width: 173, height: 215.5)))
    #expect(!RunnerElementTree.sameFrame(frame, CGRect(x: 68, y: 290.833, width: 133, height: 235)))
  }

  @Test func namesElementTypesByRawValue() {
    #expect(RunnerElementTree.typeName(rawValue: 0) == "any")
    #expect(RunnerElementTree.typeName(rawValue: 2) == "application")
    #expect(RunnerElementTree.typeName(rawValue: 9) == "button")
    #expect(RunnerElementTree.typeName(rawValue: 48) == "staticText")
    #expect(RunnerElementTree.typeName(rawValue: 49) == "textField")
    #expect(RunnerElementTree.typeName(rawValue: 75) == "cell")
    #expect(RunnerElementTree.typeName(rawValue: 82) == "statusItem")
    #expect(RunnerElementTree.typeName(rawValue: 83) == "type83")
  }

  @Test func parsesMaxDepth() {
    #expect(RunnerElementTree.maxDepth("0") == 0)
    #expect(RunnerElementTree.maxDepth("3") == 3)
    for invalid in ["", "-1", "1.5", "abc"] {
      #expect(RunnerElementTree.maxDepth(invalid) == nil, "\(invalid)")
    }
  }

  @Test func buildsJSONWithEveryKey() throws {
    var field = node("textField")
    field.identifier = "relay.input"
    field.label = "Name"
    field.value = "hello"
    field.placeholder = "Type here"
    field.frame = CGRect(x: 16, y: 83.3333333, width: 370, height: 34)
    field.hasKeyboardFocus = true
    let object = RunnerElementTree.json(node("application", children: [field]))

    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json == """
    {"children":[{"children":[],"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":83.333},\
    "hasFocus":false,"hasKeyboardFocus":true,"identifier":"relay.input","label":"Name","placeholder":"Type here","selected":false,\
    "type":"textField","value":"hello"}],"enabled":true,"frame":{"height":0,"width":0,"x":0,"y":0},\
    "hasFocus":false,"hasKeyboardFocus":null,"identifier":"","label":"","placeholder":null,"selected":false,"type":"application",\
    "value":null}
    """)
  }

  @Test func marksTruncatedChildren() {
    let object = RunnerElementTree.json(node("window", truncated: true))
    #expect(object["truncated"] as? Bool == true)
    #expect((object["children"] as? [Any])?.isEmpty == true)
    #expect(RunnerElementTree.json(node("window"))["truncated"] == nil)
  }

  @Test func roundsPoints() throws {
    let object = RunnerElementTree.json(CGPoint(x: 201, y: 213.16666666666666))
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(String(decoding: data, as: UTF8.self) == #"{"x":201,"y":213.167}"#)
  }

  private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

  private func element(
    _ type: String, identifier: String = "", label: String = "", placeholder: String? = nil,
    frame: CGRect = CGRect(x: 16, y: 100, width: 370, height: 44), enabled: Bool = true,
    children: [RunnerElementNode] = []
  ) -> RunnerElementNode {
    var element = node(type, children: children)
    element.identifier = identifier
    element.label = label
    element.placeholder = placeholder
    element.frame = frame
    element.enabled = enabled
    return element
  }

  private func filtered(_ children: [RunnerElementNode], verifyHit: (([Int], CGPoint) -> Bool?)? = nil) -> [String] {
    let root = element("application", label: "App", frame: screen, children: [element("window", frame: screen, children: children)])
    return RunnerElementTree.interactiveElements(in: root, screen: screen, verifyHit: verifyHit).map { "\($0.type) \($0.label)\($0.identifier)" }
  }

  /// The frame of the nth row of a list, so elements don't overlap.
  private func row(_ index: Int) -> CGRect {
    CGRect(x: 16, y: 100 + 50 * CGFloat(index), width: 370, height: 44)
  }

  @Test func keepsNamedControls() {
    #expect(filtered([
      element("staticText", label: "Settings", frame: row(0)),
      element("button", identifier: "com.apple.settings.general", label: "General", frame: row(1),
              children: [element("staticText", label: "General", frame: row(1))]),
      element("switch", label: "Airplane Mode", frame: row(2)),
      element("cell", identifier: "row.1", frame: row(3)),
      element("image", label: "photo", frame: row(4)),
      element("other", frame: row(5), children: [element("link", label: "Help", frame: row(5))])
    ]) == ["button Generalcom.apple.settings.general", "switch Airplane Mode", "cell row.1", "link Help"])
  }

  @Test func keepsTextInputsWithoutNames() {
    #expect(filtered([
      element("textField", frame: row(0)),
      element("searchField", placeholder: "Search", frame: row(1)),
      element("button", frame: row(2))
    ]) == ["textField ", "searchField "])
  }

  @Test func dropsDisabledAndOffscreenControls() {
    #expect(filtered([
      element("button", label: "Off", frame: row(0), enabled: false),
      element("cell", label: "Below", frame: CGRect(x: 0, y: 900, width: 402, height: 44)),
      element("cell", label: "Edge", frame: CGRect(x: 0, y: 850, width: 402, height: 44)),
      element("button", label: "Empty", frame: CGRect(x: 10, y: 10, width: 0, height: 20))
    ]) == ["cell Edge"])
  }

  /// The keys are left to relay type, and a control the keyboard covers can't be tapped.
  @Test func dropsTheKeyboardAndWhatItCovers() {
    let keyboard = CGRect(x: 0, y: 538, width: 402, height: 336)
    #expect(filtered([
      element("textField", identifier: "relay.input", frame: CGRect(x: 16, y: 86, width: 370, height: 34)),
      element("button", label: "Submit", frame: CGRect(x: 16, y: 600, width: 370, height: 44)),
      element("keyboard", frame: keyboard, children: [element("key", label: "q", frame: CGRect(x: 0, y: 550, width: 40, height: 40))])
    ]) == ["textField relay.input"])
  }

  /// Settings on iOS 27: the search bar at the bottom covers the middle of the last cell, and the search
  /// field holds two identical Dictate buttons.
  @Test func dropsControlsALaterControlCovers() {
    let dictate = CGRect(x: 342, y: 811, width: 17, height: 22)
    #expect(filtered([
      element("button", label: "StandBy", frame: CGRect(x: 16, y: 709, width: 370, height: 52)),
      element("button", label: "Screen Time", frame: CGRect(x: 16, y: 796, width: 370, height: 52)),
      element("other", frame: CGRect(x: 28, y: 798, width: 346, height: 48), children: [
        element("searchField", label: "Search", frame: CGRect(x: 28, y: 808, width: 346, height: 28), children: [
          element("button", label: "Dictate", frame: dictate),
          element("button", label: "Dictate", frame: dictate)
        ])
      ])
    ], verifyHit: { _, _ in false }) == ["button StandBy", "searchField Search", "button Dictate"])
  }

  /// A control's own contents and the controls before it are not on top of it.
  @Test func keepsControlsUnderTheirContentsAndEarlierControls() {
    #expect(filtered([
      element("button", label: "Background", frame: row(0)),
      element("cell", label: "Row", frame: row(0), children: [element("button", label: "Info", frame: row(0))])
    ], verifyHit: { _, _ in false }) == ["cell Row", "button Info"])
  }

  /// Table cells often have no label of their own; their texts name them, and tapping a text hits the cell.
  @Test func keepsTheTextsOfUnnamedControls() {
    #expect(filtered([
      element("cell", frame: row(0), children: [
        element("staticText", label: "Wi-Fi", frame: CGRect(x: 30, y: 105, width: 100, height: 30)),
        element("staticText", label: "Off", frame: CGRect(x: 300, y: 105, width: 50, height: 30)),
        element("image", frame: CGRect(x: 360, y: 105, width: 10, height: 30))
      ]),
      element("cell", frame: row(1), enabled: false, children: [element("staticText", label: "Bluetooth", frame: row(1))]),
      element("staticText", label: "Footer", frame: row(2)),
      // Settings: cell > other > button "General" > staticText "General"; the button is enough.
      element("cell", frame: row(3), children: [element("other", frame: row(3), children: [
        element("button", identifier: "com.apple.settings.general", label: "General", frame: row(3),
                children: [element("staticText", label: "General", frame: row(3))])
      ])])
    ]) == ["staticText Wi-Fi", "staticText Off", "button Generalcom.apple.settings.general"])
  }

  @Test func hitTestingKeepsFieldsInsideAnUnrelatedLabelRectangle() {
    let root = element("application", frame: screen, children: [
      element("secureTextField", label: "Password", frame: CGRect(x: 93, y: 214, width: 155, height: 21)),
      element("button", label: "Sign in", frame: CGRect(x: 251, y: 214, width: 61, height: 21)),
      element("switch", label: "I agree", frame: CGRect(x: 16, y: 211, width: 329, height: 46)),
      element("button", label: "Plan", frame: CGRect(x: 63, y: 237, width: 72, height: 21))
    ])
    var checked: [[Int]] = []
    let elements = RunnerElementTree.interactiveElements(in: root, screen: screen) { path, point in
      checked.append(path)
      return path == [0] && point == CGPoint(x: 170.5, y: 224.5) || path == [1] && point == CGPoint(x: 281.5, y: 224.5)
    }
    #expect(checked == [[0], [1]])
    #expect(RunnerElementTree.interactiveElements(in: root, screen: screen).map(\.label)
      == ["Password", "Sign in", "I agree", "Plan"])
    #expect(RunnerElementTree.interactiveElements(in: root, screen: screen) { _, _ in nil }.map(\.label)
      == ["Password", "Sign in", "I agree", "Plan"])
    #expect(elements.map(\.label) == ["Password", "Sign in", "I agree", "Plan"])
    #expect(RunnerElementTree.interactiveElements(in: root, screen: screen) { _, _ in false }.map(\.label)
      == ["I agree", "Plan"])
  }

  @Test func filteringTreatsLabelContentAndOtherControlsDifferently() {
    let root = element("application", frame: screen, children: [
      element("switch", label: "I agree", frame: CGRect(x: 16, y: 211, width: 329, height: 46)),
      element("staticText", label: "I agree", frame: CGRect(x: 16, y: 211, width: 329, height: 46)),
      element("secureTextField", label: "Password", frame: CGRect(x: 93, y: 214, width: 155, height: 21))
    ])
    func filtered(hitPath: [Int]) -> [String] {
      RunnerElementTree.interactiveElements(in: root, screen: screen) { path, point in
        guard RunnerElementTree.hitControl(at: point, path: hitPath, in: root) != nil else { return nil }
        return RunnerElementTree.isRelatedHit(hitPath, to: path)
      }.map(\.label)
    }
    #expect(filtered(hitPath: [1]) == ["I agree", "Password"])
    #expect(filtered(hitPath: [2]) == ["Password"])
  }

  @Test func filteringKeepsOverlappingControlsWhenHitCoordinatesAreUnchecked() {
    let root = element("application", frame: screen, children: [
      element("switch", label: "I agree", frame: CGRect(x: 16, y: 211, width: 329, height: 46)),
      element("secureTextField", label: "Password", frame: CGRect(x: 93, y: 214, width: 155, height: 21))
    ])
    let placed = RunnerWindowLookup.placed(RunnerWindowPlacement(
      frame: CGRect(x: 120, y: 80, width: 600, height: 800), scaleX: 1, scaleY: 1
    ))
    let contexts: [(RunnerWindowLookup?, Int)] = [(placed, 1), (.unknown("no position"), 1), (nil, 2), (.fullScreen, 2)]
    for (window, count) in contexts {
      var called = false
      var verifyHit: (([Int], CGPoint) -> Bool?)?
      if RunnerElementTree.canVerifyHit(window: window, displayCount: count) {
        verifyHit = { _, _ in called = true; return false }
      }
      let listed = RunnerElementTree.interactiveElements(in: root, screen: screen, verifyHit: verifyHit)
      #expect(!called)
      #expect(listed.map(\.label) == ["I agree", "Password"])
    }
  }

  @Test func keepsAnUnnamedCellsTextWhenTheHitIsItsAncestor() {
    let root = element("application", frame: screen, children: [
      element("cell", frame: row(0), children: [element("staticText", label: "General", frame: row(0))]),
      element("button", label: "Overlay", frame: row(0))
    ])
    var checked: [[Int]] = []
    let kept = RunnerElementTree.interactiveElements(in: root, screen: screen) { path, _ in
      checked.append(path)
      return RunnerElementTree.isRelatedHit([0], to: path)
    }
    #expect(checked == [[0, 0]])
    #expect(kept.map(\.label) == ["General", "Overlay"])
    let covered = RunnerElementTree.interactiveElements(in: root, screen: screen) { path, _ in
      RunnerElementTree.isRelatedHit([1], to: path)
    }
    #expect(covered.map(\.label) == ["Overlay"])
  }

  @Test func buildsFilteredJSON() throws {
    var field = element("textField", identifier: "relay.input", placeholder: "Type here",
                        frame: CGRect(x: 16, y: 83.3333333, width: 370, height: 34))
    field.value = "hello"
    let object = RunnerElementTree.filteredJSON([field], filter: .interactive, bundleID: "com.example")
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(String(decoding: data, as: UTF8.self) == """
    {"bundleId":"com.example","count":1,"elements":[{"frame":{"height":34,"width":370,"x":16,"y":83.333},\
    "identifier":"relay.input","label":"","placeholder":"Type here","selected":false,"type":"textField","value":"hello"}],\
    "filter":"interactive","ok":true}
    """)
  }

  @Test func writesOneLinePerElement() {
    var field = element("textField", identifier: "relay.input", label: "Name \"first\"\nline", frame: CGRect(x: 16, y: 83.6, width: 370, height: 34))
    field.value = "a/b"
    field.hasKeyboardFocus = true
    var tab = element("button", label: "Home", enabled: false)
    tab.selected = true
    #expect(RunnerElementTree.compactText([field, tab]) == """
    textField label="Name \\"first\\"\\nline" id="relay.input" value="a/b" frame=16,84,370,34 focused
    button label="Home" frame=16,100,370,44 selected disabled

    """)
  }

  @Test func indentsTheWholeTreeInCompactText() {
    let root = element("application", label: "App", frame: screen, children: [
      element("window", frame: screen, children: [element("button", label: "OK")]),
      node("other", truncated: true)
    ])
    #expect(RunnerElementTree.compactText(root) == """
    application label="App" frame=0,0,402,874
      window frame=0,0,402,874
        button label="OK" frame=16,100,370,44
      other frame=0,0,0,0 truncated

    """)
  }
}
