import Foundation

/// One element of the `/source?format=json` tree, already in the displayed orientation.
///
/// This file is compiled into both the `relay` CLI and the RelayRunnerUITests target, so the JSON the
/// runner returns is covered by the SwiftPM unit tests. The runner fills it from an `XCUIElementSnapshot`.
struct RunnerElementNode {
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
}

enum RunnerElementTree {
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
