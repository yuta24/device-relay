import Foundation

/// One element of the `/source?format=json` tree, already in the displayed orientation.
///
/// This file is compiled into both the `relay` CLI and the RelayRunnerUITests target, so the JSON the
/// runner returns is covered by the SwiftPM unit tests. The runner fills it from an `XCUIElementSnapshot`.
struct RunnerElementNode: Sendable {
  var type: String
  var identifier: String
  var label: String
  var value: String?
  var placeholder: String?
  /// Points from the top-left corner in the displayed orientation, the same space as `/tap`.
  var frame: CGRect
  var enabled: Bool
  var selected: Bool
  /// UI focus (the focus engine), which is false for a text field being typed into on iPhone.
  var hasFocus: Bool
  /// Keyboard focus, from a private snapshot property; nil when XCTest does not provide it.
  var hasKeyboardFocus: Bool?
  var children: [RunnerElementNode]
  /// True when `children` was cut off by `maxDepth`; the element has more descendants than shown.
  var truncated = false
  /// Identity in the original XCUI snapshot, retained when display/window transforms reshape the tree.
  var snapshotPath: [Int]?
  /// The part of the screen where this element can be touched, when that is less than the whole screen:
  /// the visible part of an iPad window. Not in the JSON.
  var clip: CGRect?
  /// Why the frame can't be placed on the screen, for an element inside a view another process draws whose
  /// content isn't laid out as expected (`RunnerRemoteViews`); a touch at it is refused. Not in the JSON.
  var positionUnknown: String?

  /// The part of the frame that can be touched in `screen`, null when there is none.
  func visibleFrame(in screen: CGRect) -> CGRect {
    let visible = frame.intersection(screen)
    return clip.map(visible.intersection) ?? visible
  }
}

enum RunnerElementTree {
  /// The hit-test coordinate space has only been checked without window/display placement.
  /// Remote views in a full-screen app keep using the same verification as the app.
  static func canVerifyHit(window: RunnerWindowLookup?, displayCount: Int) -> Bool {
    guard displayCount <= 1 else { return false }
    switch window {
    case nil, .fullScreen?: return true
    case .placed?, .unknown?: return false
    }
  }

  /// Finds the receiver by its identity in the original snapshot, including after display filtering.
  /// A path not present in this tree cannot establish that another element would receive the touch.
  static func node(at path: [Int], in root: RunnerElementNode) -> RunnerElementNode? {
    func visit(_ node: RunnerElementNode, path fallback: [Int]) -> RunnerElementNode? {
      if (node.snapshotPath ?? fallback) == path { return node }
      for (index, child) in node.children.enumerated() {
        if let found = visit(child, path: fallback + [index]) { return found }
      }
      return nil
    }
    return visit(root, path: [])
  }

  /// A hit on a containing control is compatible with tapping its text, just as a hit on a
  /// control's contents is compatible with tapping the control. Only a different branch can cover it.
  static func isRelatedHit(_ hitPath: [Int], to targetPath: [Int]) -> Bool {
    hitPath.starts(with: targetPath) || targetPath.starts(with: hitPath)
  }

  /// Only a known control can establish coverage. Text, images, and generic containers may forward
  /// the touch to their label or cell. Reuse interactiveTypes without the listing's naming filters.
  /// A frame or clip excluding the point is also inconclusive (Safari service chrome).
  static func hitControl(at point: CGPoint, path: [Int], in root: RunnerElementNode) -> RunnerElementNode? {
    guard let node = node(at: path, in: root), interactiveTypes.contains(node.type), node.frame.contains(point), node.clip?.contains(point) != false else { return nil }
    return node
  }

  /// `XCUIElement.ElementType` case names, indexed by raw value (XCUIElementTypes.h in Xcode 27).
  static let typeNames = [
    "any", "other", "application", "group", "window", "sheet", "drawer", "alert", "dialog", "button",
    "radioButton", "radioGroup", "checkBox", "disclosureTriangle", "popUpButton", "comboBox",
    "menuButton", "toolbarButton", "popover", "keyboard", "key", "navigationBar", "tabBar", "tabGroup",
    "toolbar", "statusBar", "table", "tableRow", "tableColumn", "outline", "outlineRow", "browser",
    "collectionView", "slider", "pageIndicator", "progressIndicator", "activityIndicator",
    "segmentedControl", "picker", "pickerWheel", "switch", "toggle", "link", "image", "icon",
    "searchField", "scrollView", "scrollBar", "staticText", "textField", "secureTextField",
    "datePicker", "textView", "menu", "menuItem", "menuBar", "menuBarItem", "map", "webView",
    "incrementArrow", "decrementArrow", "timeline", "ratingIndicator", "valueIndicator", "splitGroup",
    "splitter", "relevanceIndicator", "colorWell", "helpTag", "matte", "dockItem", "ruler",
    "rulerMarker", "grid", "levelIndicator", "cell", "layoutArea", "layoutItem", "handle", "stepper",
    "tab", "touchBar", "statusItem"
  ]

  /// The case name for an element type's raw value; unknown future types become `type<raw>`.
  static func typeName(rawValue: UInt) -> String {
    rawValue < typeNames.count ? typeNames[Int(rawValue)] : "type\(rawValue)"
  }

  /// A `maxDepth` query value: a non-negative integer, where 0 is the root only. Nil when invalid.
  static func maxDepth(_ value: String) -> Int? {
    guard let depth = Int(value), depth >= 0 else { return nil }
    return depth
  }

  /// The JSON object for `node`. Absent value, placeholder, and keyboard focus are `null` so every
  /// element has the same keys; frames are rounded to 1/1000 point to keep the payload small.
  static func json(_ node: RunnerElementNode) -> [String: Any] {
    var object: [String: Any] = [
      "type": node.type,
      "identifier": node.identifier,
      "label": node.label,
      "value": node.value ?? NSNull(),
      "placeholder": node.placeholder ?? NSNull(),
      "frame": json(node.frame),
      "enabled": node.enabled,
      "selected": node.selected,
      "hasFocus": node.hasFocus,
      "hasKeyboardFocus": node.hasKeyboardFocus ?? NSNull(),
      "children": node.children.map(json)
    ]
    if node.truncated {
      object["truncated"] = true
    }
    return object
  }

  /// `{"x","y","width","height"}`, rounded like every frame in `/source`.
  static func json(_ frame: CGRect) -> [String: Any] {
    [
      "x": rounded(frame.origin.x),
      "y": rounded(frame.origin.y),
      "width": rounded(frame.size.width),
      "height": rounded(frame.size.height)
    ]
  }

  /// `{"x","y"}`, rounded the same way, for the point `/tap` touched.
  static func json(_ point: CGPoint) -> [String: Any] {
    ["x": rounded(point.x), "y": rounded(point.y)]
  }

  /// JSONSerialization writes a Double with 17 significant digits (83.333 becomes 83.332999999999998),
  /// so go through the shortest decimal representation instead.
  private static func rounded(_ value: CGFloat) -> NSDecimalNumber {
    guard value.isFinite else { return 0 }
    return NSDecimalNumber(string: String((Double(value) * 1000).rounded() / 1000))
  }
}

// MARK: - Filtered and compact output

extension RunnerElementTree {
  /// The `filter` query values of `/source`.
  enum Filter: String {
    /// The elements an agent can act on; see `interactiveElements(in:screen:)`.
    case interactive
  }

  /// The `format` query values of `/source`. `text` is XCUI's `debugDescription`, which the runner makes.
  static let formats = ["json", "text", "compact"]

  /// Types a touch or text input does something to. Containers (`table`, `segmentedControl`, ...) are
  /// left out because their buttons and cells are listed themselves; keyboard keys because `/type` and
  /// `/key` type without them.
  static let interactiveTypes: Set<String> = [
    "button", "cell", "link", "icon", "tab", "switch", "toggle", "slider", "stepper", "pickerWheel",
    "textField", "secureTextField", "searchField", "textView", "radioButton", "checkBox", "comboBox",
    "popUpButton", "menuButton", "menuItem", "toolbarButton", "disclosureTriangle", "pageIndicator",
    "incrementArrow", "decrementArrow"
  ]
  static let textInputTypes: Set<String> = ["textField", "secureTextField", "searchField", "textView"]

  /// The elements worth acting on, in document order and without children: an `interactiveTypes` element
  /// that is enabled, shows inside `screen` (points in the displayed orientation), is not under the
  /// keyboard, and has an identifier, label, or placeholder (text inputs are kept without any, so
  /// `--type textField --index n` still has them). When such a control has none of these, as a table
  /// cell often doesn't, its labeled static texts are kept instead (unless a named control inside it is
  /// listed): tapping one of them hits the control.
  ///
  /// Keyboard coverage is checked from the snapshot. A later unrelated control covering the center
  /// is only a possible obstruction (a wrapped web label's rectangle can surround other controls).
  /// `verifyHit` drops such a candidate only when hit testing confirms an unrelated control.
  /// Unknown hits keep the candidate. Overlays that aren't controls aren't filtered here; touches verify separately.
  static func interactiveElements(
    in root: RunnerElementNode, screen: CGRect, verifyHit: (([Int], CGPoint) -> Bool?)? = nil
  ) -> [RunnerElementNode] {
    var keyboards: [CGRect] = []
    func findKeyboards(_ node: RunnerElementNode) {
      if node.type == "keyboard" {
        keyboards.append(node.frame)
        return
      }
      node.children.forEach(findKeyboards)
    }
    findKeyboards(root)

    /// Where a selector taps: the center of the part of the frame on screen, as `resolve` computes it.
    func tapPoint(_ node: RunnerElementNode) -> CGPoint? {
      let visible = node.visibleFrame(in: screen)
      guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
      let center = CGPoint(x: visible.midX, y: visible.midY)
      return keyboards.contains { $0.contains(center) } ? nil : center
    }

    func isNamed(_ node: RunnerElementNode) -> Bool {
      !node.identifier.isEmpty || !node.label.isEmpty || !(node.placeholder ?? "").isEmpty
    }
    func isListedControl(_ node: RunnerElementNode) -> Bool {
      interactiveTypes.contains(node.type) && (isNamed(node) || textInputTypes.contains(node.type))
    }
    func containsListedControl(_ node: RunnerElementNode) -> Bool {
      node.children.contains { isListedControl($0) || containsListedControl($0) }
    }

    // Candidates in document order, with the position after their subtree, so that a later control
    // that isn't a descendant can be told apart from the candidate's own contents.
    var candidates: [(node: RunnerElementNode, point: CGPoint, isControl: Bool, subtreeEnd: Int, path: [Int])] = []
    var position = 0
    func visit(_ node: RunnerElementNode, path: [Int], insideUnlabeledControl: Bool) {
      guard node.type != "keyboard" else { return }
      position += 1
      var candidate: Int?
      var unlabeledControl = insideUnlabeledControl
      if isListedControl(node) {
        if node.enabled, let point = tapPoint(node) {
          candidate = candidates.count
          candidates.append((withoutChildren(node), point, true, 0, node.snapshotPath ?? path))
        }
      } else if interactiveTypes.contains(node.type) {
        // A Settings cell holds a named button, which is listed instead of the texts.
        unlabeledControl = node.enabled && !containsListedControl(node)
      } else if insideUnlabeledControl, node.type == "staticText", isNamed(node), let point = tapPoint(node) {
        candidate = candidates.count
        candidates.append((withoutChildren(node), point, false, 0, node.snapshotPath ?? path))
      }
      for (index, child) in node.children.enumerated() {
        visit(child, path: path + [index], insideUnlabeledControl: unlabeledControl)
      }
      if let candidate {
        candidates[candidate].subtreeEnd = position
      }
    }
    visit(root, path: [], insideUnlabeledControl: false)

    // Later controls may be drawn on top, but bounding rectangles alone don't prove that. Descendants
    // aren't obstructions; a later unrelated candidate ends after this candidate's subtree.
    return candidates.enumerated().filter { index, candidate in
      let possiblyCovered = candidates[(index + 1)...].contains { later in
        later.isControl && later.subtreeEnd > candidate.subtreeEnd && later.node.frame.contains(candidate.point)
      }
      return !possiblyCovered || verifyHit?(candidate.path, candidate.point) != false
    }.map(\.element.node)
  }

  private static func withoutChildren(_ node: RunnerElementNode) -> RunnerElementNode {
    var element = node
    element.children = []
    element.truncated = false
    return element
  }

  /// The JSON of a filtered element: what selectors match on (`type`, `identifier`, `label`, `value`),
  /// the `placeholder` that names an empty text field, `frame`, and `selected` (tabs, segments).
  static func elementJSON(_ node: RunnerElementNode) -> [String: Any] {
    [
      "type": node.type,
      "identifier": node.identifier,
      "label": node.label,
      "value": node.value ?? NSNull(),
      "placeholder": node.placeholder ?? NSNull(),
      "frame": json(node.frame),
      "selected": node.selected
    ]
  }

  /// The `/source?filter=interactive` body.
  static func filteredJSON(_ elements: [RunnerElementNode], filter: Filter, bundleID: String) -> [String: Any] {
    [
      "ok": true,
      "bundleId": bundleID,
      "filter": filter.rawValue,
      "count": elements.count,
      "elements": elements.map(elementJSON)
    ]
  }

  /// `format=compact`: one line per element, the whole tree indented by depth, or the filtered elements
  /// flat. Each line ends with a newline.
  static func compactText(_ root: RunnerElementNode) -> String {
    var lines: [String] = []
    func visit(_ node: RunnerElementNode, depth: Int) {
      lines.append(String(repeating: "  ", count: depth) + compactLine(node))
      node.children.forEach { visit($0, depth: depth + 1) }
    }
    visit(root, depth: 0)
    return lines.map { $0 + "\n" }.joined()
  }

  static func compactText(_ elements: [RunnerElementNode]) -> String {
    elements.map { compactLine($0) + "\n" }.joined()
  }

  /// `button label="General" id="com.apple.settings.general" frame=16,380,370,52`: the type, then the
  /// non-empty `label`, `id` (identifier), `value`, and `placeholder` as JSON strings, named like the
  /// selector options, then the frame (x,y,width,height in whole points) and the `selected`, `focused`
  /// (keyboard focus), `disabled`, and `truncated` flags that are set.
  static func compactLine(_ node: RunnerElementNode) -> String {
    var parts = [node.type]
    for (name, value) in [("label", node.label), ("id", node.identifier), ("value", node.value ?? ""),
                          ("placeholder", node.placeholder ?? "")] where !value.isEmpty {
      parts.append("\(name)=\(quoted(value))")
    }
    let frame = [node.frame.origin.x, node.frame.origin.y, node.frame.size.width, node.frame.size.height]
      .map { $0.isFinite ? String(Int($0.rounded())) : "0" }
    parts.append("frame=" + frame.joined(separator: ","))
    if node.selected { parts.append("selected") }
    if node.hasKeyboardFocus == true { parts.append("focused") }
    if !node.enabled { parts.append("disabled") }
    if node.truncated { parts.append("truncated") }
    return parts.joined(separator: " ")
  }

  /// A JSON string literal, so labels with quotes or line breaks stay on one line.
  private static func quoted(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
  }
}

extension RunnerElementTree {
  /// Whether two frames of one element, read by two snapshots, are the same: by default within a hundredth of a
  /// point, as reading the same layout twice can differ in the last bits.
  static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
      && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
  }

  /// How close an `XCUIElement`'s frame must be to the screen frame of an element of a placed iPad window. Its
  /// snapshot frame is in the window's coordinates, but `XCUIElement.frame` is on the screen, scaled by XCUI a little
  /// differently from `RunnerWindowPlacement`: a slider of a window at 0.64 was at x 40.577, 752.847 wide for XCUI and
  /// 40.235, 753.531 wide here (some 0.7 point at most across an 11-inch iPad).
  static let placedWindowFrameTolerance: CGFloat = 2

  /// The frame to find an element's `XCUIElement` by, and how close its frame must be: the snapshot's frame, exactly,
  /// except in a placed iPad window (`window` is `.placed`), where it is the frame on the screen (`onScreen`), within
  /// `placedWindowFrameTolerance`.
  static func xcuiFrame(snapshot: CGRect, onScreen: CGRect, window: RunnerWindowLookup?) -> (frame: CGRect, tolerance: CGFloat) {
    guard case .placed? = window else { return (snapshot, 0.01) }
    return (onScreen, placedWindowFrameTolerance)
  }
}
