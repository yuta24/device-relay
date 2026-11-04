import CoreGraphics
import Foundation

/// Where an app's window is on the screen. On iPad, windowed apps (Windowed Apps, Stage Manager, Slide Over)
/// report every element relative to their own window, starting at (0, 0), so these frames are not the screen
/// coordinates that touches and screenshots use.
struct RunnerWindowPlacement: Equatable {
    /// The window on the screen, in points in the displayed orientation.
    var frame: CGRect
    /// Screen points per window point. It is 1 for an app whose scene follows the window. An app that can't be
    /// resized (`UIRequiresFullScreen`) keeps a screen-sized scene, and SpringBoard shows it scaled down.
    var scaleX: CGFloat
    var scaleY: CGFloat
    /// The origin of the app's own space, which the app's root element reports.
    var appOrigin: CGPoint = .zero

    func onScreen(_ rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + (rect.minX - appOrigin.x) * scaleX, y: frame.minY + (rect.minY - appOrigin.y) * scaleY,
               width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// `root` (an app's snapshot, whose children are its windows) in screen coordinates. Each element also gets
    /// the visible part of the window as its `clip`: a frame scrolled out of the window can't be touched.
    ///
    /// The system keyboard of a resizable app isn't part of the window. It has a window of its own that spans the
    /// screen, in the native portrait space, whatever the shape of the app's window (`isScreenWindow`).
    func onScreen(root: RunnerElementNode, screen: CGSize, orientation: RunnerInterfaceOrientation, portraitSize: CGSize) -> RunnerElementNode {
        let clip = CGRect(origin: .zero, size: screen).intersection(frame)
        func inWindow(_ node: RunnerElementNode) -> RunnerElementNode {
            var node = node
            node.frame = onScreen(node.frame)
            node.clip = clip
            node.children = node.children.map(inWindow)
            return node
        }
        var result = root
        result.frame = onScreen(root.frame)
        result.clip = clip
        result.children = root.children.map { window in
            RunnerWindows.isScreenWindow(window, appFrame: root.frame, orientation: orientation, portraitSize: portraitSize)
                ? RunnerWindows.inScreenWindow(window, orientation: orientation, portraitSize: portraitSize)
                : inWindow(window)
        }
        return result
    }

    /// The `window` field of responses. The two scales differ only by the rounding of SpringBoard's frame, so
    /// one is reported.
    var json: [String: Any] {
        var object = RunnerElementTree.json(frame)
        object["scale"] = NSDecimalNumber(string: RunnerRequestValues.decimal(scaleX))
        return object
    }
}

/// What looking the window up gave for one command.
enum RunnerWindowLookup: Equatable {
    /// The window fills the screen: frames already are screen coordinates.
    case fullScreen
    case placed(RunnerWindowPlacement)
    /// The frames can't be turned into screen coordinates; the text says why.
    case unknown(String)
}

/// The decisions about iPad windows. Like `RunnerDisplays.swift`, this file is compiled into both the `relay`
/// CLI and the runner target so the SwiftPM unit tests cover it; the runner only reads the snapshots.
enum RunnerWindows {
    /// How the identifier of SpringBoard's window that holds the app windows starts. What follows varies:
    /// `SBSwitcherWindow:Main` on an iPad, `SBSwitcherWindow:Unknown.main[3]` seen on an unfolded iPhone Duo.
    /// Snapshotting only this window takes about 15 ms, against about 35–55 ms for all of SpringBoard on an iPad
    /// mini simulator.
    static let switcherWindowIdentifierPrefix = "SBSwitcherWindow:"
    /// Finds that window in a query of SpringBoard's windows.
    static var switcherWindowPredicate: NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH %@", switcherWindowIdentifierPrefix)
    }
    static let springboardBundleID = "com.apple.springboard"
    /// The Dock's folder (Recents and Downloads): a service that stays active in Windowed Apps mode with a
    /// screen-sized window of its own, and is at times listed ahead of the app the user sees.
    static let dockFolderServiceBundleID = "com.apple.DocumentManager.DockFolderViewService"
    /// The most the two scales of one window may differ: an iPad mini simulator showed at most 0.001, from the
    /// rounding of SpringBoard's frame. More means the frames are not of the same window or space.
    static let scaleTolerance: CGFloat = 0.02
    /// How far from the screen's edges a window that fills the screen may be, in points.
    static let fullScreenTolerance: CGFloat = 0.5

    /// The entry of the active applications that is in the foreground: the first, leaving out the Dock's folder
    /// service. Nil when nothing else is listed.
    static func foregroundIndex(activeBundleIDs: [String]) -> Int? {
        activeBundleIDs.firstIndex { $0 != dockFolderServiceBundleID }
    }

    /// Whether SpringBoard's element `identifier` is a window of `bundleID`:
    /// `card:<bundle ID>:sceneID:<scene>`, one per scene. Windows hidden in the switcher have one too.
    static func isCard(identifier: String, of bundleID: String) -> Bool {
        identifier == "card:\(bundleID)" || identifier.hasPrefix("card:\(bundleID):")
    }

    /// Whether the app may be in a window, so SpringBoard has to be asked. In Full Screen Apps mode SpringBoard
    /// isn't among the active applications, so an app that fills the screen costs nothing more. In the other
    /// modes it is always listed, because a window that looks full-size can still be a scaled-down one.
    /// `activeBundleIDs` is nil when the list can't be read.
    static func mayBeWindowed(appFrame: CGRect, screen: CGSize, activeBundleIDs: [String]?) -> Bool {
        guard let activeBundleIDs, !activeBundleIDs.contains(springboardBundleID) else { return true }
        return !fills(appFrame, screen: screen)
    }

    /// `card` (a frame from SpringBoard's tree) in the displayed orientation. SpringBoard's frames stay in the
    /// native portrait space on iPad, as its windows (`container`) show. A landscape container means they are
    /// already displayed ones.
    static func displayedFrame(
        card: CGRect, container: CGRect, orientation: RunnerInterfaceOrientation, portraitSize: CGSize
    ) -> CGRect {
        guard orientation.isLandscape ? container.height > container.width : orientation == .portraitUpsideDown else { return card }
        return RunnerDisplays.interfaceRect(fromPortrait: card, orientation: orientation, portraitSize: portraitSize)
    }

    /// Decides where the app's window is. `appFrame` is the root element of the app's snapshot, `cards` the
    /// frames in the displayed orientation of its windows from SpringBoard (nil when SpringBoard couldn't be read).
    static func lookup(bundleID: String, appFrame: CGRect, cards: [CGRect]?, screen: CGSize) -> RunnerWindowLookup {
        guard let cards else {
            return .unknown(message(bundleID, "SpringBoard's tree could not be read"))
        }
        guard let card = cards.first else {
            // Nothing says it is a window, and nothing would be wrong with its frames if it fills the screen.
            return fills(appFrame, screen: screen)
                ? .fullScreen
                : .unknown(message(bundleID, "SpringBoard lists no window of it"))
        }
        // The app's tree doesn't say which scene an element belongs to, and the scenes' windows all start at (0, 0).
        guard cards.count == 1 else {
            return .unknown(message(bundleID, "it has \(cards.count) windows open and elements can't be told apart by window"))
        }
        guard appFrame.width > 0, appFrame.height > 0, card.width > 0, card.height > 0 else {
            return .unknown(message(bundleID, "its window has an empty frame"))
        }
        let scaleX = card.width / appFrame.width, scaleY = card.height / appFrame.height
        guard abs(scaleX - scaleY) <= scaleTolerance else {
            return .unknown(message(bundleID, "SpringBoard's window (\(describe(card.size))) doesn't match the app's (\(describe(appFrame.size)))"))
        }
        if fills(card, screen: screen), fills(appFrame, screen: screen) {
            return .fullScreen
        }
        return .placed(RunnerWindowPlacement(frame: card, scaleX: scaleX, scaleY: scaleY, appOrigin: appFrame.origin))
    }

    /// A top-level window of the app whose elements are in the native portrait space and span the screen, unlike
    /// the app's own window: the system keyboard's. In a window it is told by its screen size, and in landscape by
    /// its keyboard, which stands on its side (its window can report the displayed size). A scaled app's keyboard
    /// has the app's size and lies flat, because it is inside the window, so it isn't one of these.
    static func isScreenWindow(
        _ window: RunnerElementNode, appFrame: CGRect, orientation: RunnerInterfaceOrientation, portraitSize: CGSize
    ) -> Bool {
        let tolerance = fullScreenTolerance
        let isScreenSized = abs(window.frame.width - portraitSize.width) <= tolerance && abs(window.frame.height - portraitSize.height) <= tolerance
        let isAppSized = abs(appFrame.width - window.frame.width) <= tolerance && abs(appFrame.height - window.frame.height) <= tolerance
        if isScreenSized, !isAppSized { return true }
        return orientation.isLandscape && hasSidewaysKeyboard(window, orientation: orientation)
    }

    private static func hasSidewaysKeyboard(_ node: RunnerElementNode, orientation: RunnerInterfaceOrientation) -> Bool {
        if node.type == "keyboard" { return RunnerDisplays.isPortrait(node.frame, in: orientation) }
        return node.children.contains { hasSidewaysKeyboard($0, orientation: orientation) }
    }

    /// `root` of an app that fills the screen: only its keyboard's window, in landscape, needs converting.
    static func fullScreenTree(_ root: RunnerElementNode, orientation: RunnerInterfaceOrientation, portraitSize: CGSize) -> RunnerElementNode {
        guard orientation.isLandscape else { return root }
        var result = root
        result.children = root.children.map { window in
            isScreenWindow(window, appFrame: root.frame, orientation: orientation, portraitSize: portraitSize)
                ? inScreenWindow(window, orientation: orientation, portraitSize: portraitSize)
                : window
        }
        return result
    }

    /// A screen window's elements from the native portrait space, to the displayed orientation. Upside down, such
    /// a window has the same size as the app's and its keyboard lies flat like any other, so it is left as is.
    fileprivate static func inScreenWindow(_ window: RunnerElementNode, orientation: RunnerInterfaceOrientation, portraitSize: CGSize) -> RunnerElementNode {
        guard orientation.isLandscape else { return window }
        func converted(_ node: RunnerElementNode) -> RunnerElementNode {
            var node = node
            node.frame = RunnerDisplays.interfaceRect(fromPortrait: node.frame, orientation: orientation, portraitSize: portraitSize)
            node.children = node.children.map(converted)
            return node
        }
        var result = converted(window)
        result.frame = CGRect(origin: .zero, size: RunnerDisplays.screenSize(portrait: portraitSize, orientation: orientation))
        return result
    }

    /// Adds what a `/find`, `/source`, or element touch response says about the window: nothing when the
    /// frames need no conversion, so these responses stay as they are; `window` when they were converted;
    /// `window: null` and `warning` when they could not be.
    static func annotate(_ body: inout [String: Any], lookup: RunnerWindowLookup?) {
        switch lookup {
        case nil, .fullScreen?:
            break
        case .placed(let placement)?:
            body["window"] = placement.json
        case .unknown(let message)?:
            body["window"] = NSNull()
            body["warning"] = warning(message)
        }
    }

    /// The first line of `/source?format=compact` when frames are left in window coordinates.
    static func compactWarning(lookup: RunnerWindowLookup?) -> String {
        guard case .unknown(let message)? = lookup else { return "" }
        return "warning \(warning(message))\n"
    }

    /// The 422 of a touch at an element: its frame says nothing about the screen.
    static func touchError(_ message: String) -> String {
        "\(message); nothing was sent. Touch by coordinates from a screenshot instead"
    }

    private static func warning(_ message: String) -> String {
        "\(message); frames are relative to the window, not the screen"
    }

    private static func message(_ bundleID: String, _ reason: String) -> String {
        "cannot tell where the window of \(bundleID) is on the screen: \(reason)"
    }

    private static func fills(_ frame: CGRect, screen: CGSize) -> Bool {
        abs(frame.minX) <= fullScreenTolerance && abs(frame.minY) <= fullScreenTolerance
            && abs(frame.width - screen.width) <= fullScreenTolerance && abs(frame.height - screen.height) <= fullScreenTolerance
    }

    private static func describe(_ size: CGSize) -> String {
        "\(RunnerRequestValues.decimal(size.width))x\(RunnerRequestValues.decimal(size.height))"
    }
}
