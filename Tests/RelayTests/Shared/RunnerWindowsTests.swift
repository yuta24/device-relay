import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerWindowsTests {
    static let bundleID = "com.example.app"
    static let landscape = CGSize(width: 1133, height: 744)
    static let portrait = CGSize(width: 744, height: 1133)

    private func node(_ type: String = "other", frame: CGRect, children: [RunnerElementNode] = []) -> RunnerElementNode {
        RunnerElementNode(type: type, identifier: "", label: "", value: nil, placeholder: nil, frame: frame, enabled: true,
                          selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children)
    }

    private func placement(_ lookup: RunnerWindowLookup) throws -> RunnerWindowPlacement {
        guard case .placed(let placement) = lookup else {
            Issue.record("expected a placement, got \(lookup)")
            throw CancellationError()
        }
        return placement
    }

    // MARK: Placement

    /// The report: a 794x530 window at (170, 50) on a landscape iPad mini. The button's center is (567, 443).
    @Test func placesAResizableWindowAtItsOrigin() throws {
        let lookup = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(x: 0, y: 0, width: 794, height: 530),
                                          cards: [CGRect(x: 170, y: 50, width: 794, height: 530)], screen: Self.landscape)
        let window = try placement(lookup)
        #expect(window.scaleX == 1 && window.scaleY == 1)
        let button = window.onScreen(CGRect(x: 253, y: 373.5, width: 288, height: 40))
        #expect(button == CGRect(x: 423, y: 423.5, width: 288, height: 40))
        #expect(button.midX == 567 && button.midY == 443.5)
    }

    /// `UIRequiresFullScreen`: the scene stays 1133x744 and the window is shown at 957x629.
    @Test func placesAScaledWindowWithItsScale() throws {
        let lookup = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(origin: .zero, size: Self.landscape),
                                          cards: [CGRect(x: 66, y: 32, width: 957, height: 629)], screen: Self.landscape)
        let window = try placement(lookup)
        let field = window.onScreen(CGRect(x: 16, y: 102, width: 1101, height: 34))
        #expect(abs(field.midX - 544.5) < 1)
        #expect(abs(field.midY - 132.6) < 1)
        #expect(abs(field.width - 930) < 1)
    }

    @Test func convertsAWholeTree() throws {
        let window = RunnerWindowPlacement(frame: CGRect(x: 100, y: 200, width: 50, height: 50), scaleX: 0.5, scaleY: 0.5)
        let root = node("application", frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [
            node(frame: CGRect(x: 10, y: 20, width: 40, height: 40), children: [node("button", frame: CGRect(x: 20, y: 40, width: 4, height: 2))])
        ])
        let converted = window.onScreen(root: root, screen: Self.landscape, orientation: .portrait, portraitSize: Self.portrait)
        #expect(converted.frame == window.frame)
        #expect(converted.children[0].frame == CGRect(x: 105, y: 210, width: 20, height: 20))
        #expect(converted.children[0].children[0].frame == CGRect(x: 110, y: 220, width: 2, height: 1))
    }

    @Test func aWindowThatFillsTheScreenNeedsNoConversion() {
        let screen = CGRect(origin: .zero, size: Self.portrait)
        #expect(RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: screen, cards: [screen], screen: Self.portrait) == .fullScreen)
        // SpringBoard's frames can differ by rounding.
        #expect(RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: screen, cards: [screen.insetBy(dx: 0.25, dy: 0.25)],
                                     screen: Self.portrait) == .fullScreen)
    }

    /// A screen-sized scene isn't full screen when SpringBoard shows it smaller.
    @Test func aScreenSizedSceneInASmallerWindowIsConverted() throws {
        let scaled = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(origin: .zero, size: Self.portrait),
                                          cards: [CGRect(x: 0, y: 59, width: 668, height: 1018)], screen: Self.portrait)
        #expect(abs(try placement(scaled).scaleX - 0.898) < 0.001)
    }

    // MARK: When the position can't be told

    @Test func unreadableSpringBoardIsUnknown() {
        let lookup = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(origin: .zero, size: Self.portrait), cards: nil,
                                          screen: Self.portrait)
        guard case .unknown(let message) = lookup else {
            Issue.record("expected unknown, got \(lookup)")
            return
        }
        #expect(message.contains(Self.bundleID))
    }

    @Test func aMissingCardIsUnknownOnlyForASmallerWindow() {
        let small = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(x: 0, y: 0, width: 794, height: 530), cards: [],
                                         screen: Self.landscape)
        guard case .unknown = small else {
            Issue.record("expected unknown, got \(small)")
            return
        }
        #expect(RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(origin: .zero, size: Self.landscape), cards: [],
                                     screen: Self.landscape) == .fullScreen)
    }

    /// Scenes of an app overlap in its tree, so it isn't known which window an element is in.
    @Test func severalWindowsOfOneAppAreUnknown() {
        let lookup = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(x: 0, y: 0, width: 375, height: 486),
                                          cards: [CGRect(x: 185, y: 324, width: 375, height: 486), CGRect(x: 186.5, y: 326, width: 372, height: 482)],
                                          screen: Self.portrait)
        guard case .unknown(let message) = lookup else {
            Issue.record("expected unknown, got \(lookup)")
            return
        }
        #expect(message.contains("2 windows"))
    }

    @Test func aCardOfAnotherShapeIsUnknown() {
        // Frames in the wrong space, for one: a landscape window read in portrait coordinates.
        let lookup = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: CGRect(x: 0, y: 0, width: 794, height: 530),
                                          cards: [CGRect(x: 50, y: 170, width: 530, height: 794)], screen: Self.landscape)
        guard case .unknown(let message) = lookup else {
            Issue.record("expected unknown, got \(lookup)")
            return
        }
        #expect(message.contains("530x794"))
        let empty = RunnerWindows.lookup(bundleID: Self.bundleID, appFrame: .zero, cards: [CGRect(x: 0, y: 0, width: 10, height: 10)], screen: Self.landscape)
        guard case .unknown = empty else {
            Issue.record("expected unknown, got \(empty)")
            return
        }
    }

    // MARK: Whether to look

    @Test func looksUpWindowsUnlessTheAppFillsTheScreenInFullScreenMode() {
        let full = CGRect(origin: .zero, size: Self.portrait)
        let small = CGRect(x: 0, y: 0, width: 500, height: 700)
        #expect(!RunnerWindows.mayBeWindowed(appFrame: full, screen: Self.portrait, activeBundleIDs: ["com.example.app"]))
        // SpringBoard listed: Windowed Apps or Stage Manager, where a full-size scene can be scaled down.
        #expect(RunnerWindows.mayBeWindowed(appFrame: full, screen: Self.portrait, activeBundleIDs: ["com.example.app", RunnerWindows.springboardBundleID]))
        #expect(RunnerWindows.mayBeWindowed(appFrame: small, screen: Self.portrait, activeBundleIDs: ["com.example.app"]))
        #expect(RunnerWindows.mayBeWindowed(appFrame: full, screen: Self.portrait, activeBundleIDs: nil))
    }

    // MARK: Orientation of SpringBoard's frames

    /// Seen on an iPad mini simulator with a 533x744 window that is at (292, 12) in `landscapeLeft`
    /// (interface landscapeRight) and at (292, 0) in `landscapeRight` (interface landscapeLeft).
    @Test func convertsCardsFromTheNativeSpace() {
        let container = CGRect(origin: .zero, size: Self.portrait)
        #expect(RunnerWindows.displayedFrame(card: CGRect(x: -12, y: 292, width: 744, height: 533), container: container,
                                             orientation: .landscapeRight, portraitSize: Self.portrait)
            == CGRect(x: 292, y: 12, width: 533, height: 744))
        #expect(RunnerWindows.displayedFrame(card: CGRect(x: 0, y: 308, width: 744, height: 533), container: container,
                                             orientation: .landscapeLeft, portraitSize: Self.portrait)
            == CGRect(x: 292, y: 0, width: 533, height: 744))
        #expect(RunnerWindows.displayedFrame(card: CGRect(x: 100, y: 207, width: 533, height: 756), container: container,
                                             orientation: .portrait, portraitSize: Self.portrait)
            == CGRect(x: 100, y: 207, width: 533, height: 756))
        #expect(RunnerWindows.displayedFrame(card: CGRect(x: 100, y: 207, width: 533, height: 756), container: container,
                                             orientation: .portraitUpsideDown, portraitSize: Self.portrait)
            == CGRect(x: 111, y: 170, width: 533, height: 756))
    }

    @Test func leavesCardsAloneWhenSpringBoardIsAlreadyLandscape() {
        let card = CGRect(x: 170, y: 50, width: 794, height: 530)
        #expect(RunnerWindows.displayedFrame(card: card, container: CGRect(origin: .zero, size: Self.landscape),
                                             orientation: .landscapeRight, portraitSize: Self.portrait) == card)
    }

    // MARK: Cards and the foreground

    @Test func switcherWindowIsFoundWhateverFollowsThePrefix() {
        let predicate = RunnerWindows.switcherWindowPredicate
        #expect(predicate.evaluate(with: ["identifier": "SBSwitcherWindow:Main"]))
        #expect(predicate.evaluate(with: ["identifier": "SBSwitcherWindow:Unknown.main[3]"]))
        #expect(!predicate.evaluate(with: ["identifier": "SBSwitcherWindow"]))
        #expect(!predicate.evaluate(with: ["identifier": "SBHomeScreenWindow:SBSwitcherWindow:Main"]))
        #expect(!predicate.evaluate(with: ["identifier": ""]))
    }

    @Test func recognizesTheCardsOfAnApp() {
        #expect(RunnerWindows.isCard(identifier: "card:com.example.app:sceneID:com.example.app-1234", of: Self.bundleID))
        #expect(RunnerWindows.isCard(identifier: "card:com.example.app", of: Self.bundleID))
        // Another app whose bundle ID starts the same, and other elements.
        #expect(!RunnerWindows.isCard(identifier: "card:com.example.app2:sceneID:x", of: Self.bundleID))
        #expect(!RunnerWindows.isCard(identifier: "window-controls:com.example.app", of: Self.bundleID))
    }

    @Test func theForegroundLeavesOutTheDockFolderService() {
        let dock = RunnerWindows.dockFolderServiceBundleID, board = RunnerWindows.springboardBundleID
        // The lists seen on an iPad mini simulator: on the home screen, and with an app on screen.
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: [dock, board]) == 1)
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: [dock, "com.apple.mobilesafari", board]) == 1)
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: ["com.example.app", dock, board]) == 0)
        // iPhone, and a view service that is what the user is looking at.
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: ["com.example.app"]) == 0)
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: ["com.apple.SafariViewService", "com.example.app"]) == 0)
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: [dock]) == nil)
        #expect(RunnerWindows.foregroundIndex(activeBundleIDs: []) == nil)
    }

    // MARK: Keyboard window

    /// A 621x486 window with the keyboard's window, from the 744x1133 native space: its keys stay where they are.
    @Test func theKeyboardWindowOfAResizableAppIsNotInTheAppWindow() {
        let window = RunnerWindowPlacement(frame: CGRect(x: 256, y: 72, width: 621, height: 486), scaleX: 1, scaleY: 1)
        let key = node("key", frame: CGRect(x: 277, y: 4, width: 86, height: 103))
        let keyboardWindow = node("window", frame: CGRect(origin: .zero, size: Self.portrait), children: [key])
        let appWindow = node("window", frame: CGRect(x: 0, y: 0, width: 621, height: 486),
                             children: [node("textField", frame: CGRect(x: 16, y: 34, width: 589, height: 34))])
        let root = node("application", frame: CGRect(x: 0, y: 0, width: 621, height: 486), children: [appWindow, keyboardWindow])
        let converted = window.onScreen(root: root, screen: Self.landscape, orientation: .landscapeRight, portraitSize: Self.portrait)
        #expect(converted.frame == window.frame)
        #expect(converted.children[0].children[0].frame == CGRect(x: 272, y: 106, width: 589, height: 34))
        // Shown at the bottom of the screen, across it, outside the window.
        #expect(converted.children[1].children[0].frame == CGRect(x: 4, y: 381, width: 103, height: 86))
        #expect(converted.children[1].children[0].clip == nil)
    }

    /// An app that can't be resized has a screen-sized scene, and its keyboard is inside the scaled window.
    @Test func theKeyboardWindowOfAScaledAppIsInTheAppWindow() {
        let app = CGRect(origin: .zero, size: Self.portrait)
        let flat = node("keyboard", frame: CGRect(x: 0, y: 848, width: 744, height: 282))
        let window = node("window", frame: app, children: [flat])
        #expect(!RunnerWindows.isScreenWindow(window, appFrame: app, orientation: .landscapeRight, portraitSize: Self.portrait))
        #expect(!RunnerWindows.isScreenWindow(window, appFrame: app, orientation: .portrait, portraitSize: Self.portrait))
        let small = CGRect(x: 0, y: 0, width: 375, height: 486)
        #expect(RunnerWindows.isScreenWindow(window, appFrame: small, orientation: .portrait, portraitSize: Self.portrait))
        #expect(!RunnerWindows.isScreenWindow(node("window", frame: small), appFrame: small, orientation: .portrait, portraitSize: Self.portrait))
    }

    /// A landscape app that fills the screen: the keyboard's window reports the displayed size (1133x744) and its
    /// keyboard stands on its side. Upside down it can't be told.
    @Test func theKeyboardWindowOfAFullScreenAppIsConvertedInLandscape() {
        let key = node("key", frame: CGRect(x: 467, y: 985, width: 85.5, height: 103))
        let keyboard = node("keyboard", frame: CGRect(x: 371, y: 0, width: 370, height: 1133), children: [key])
        let screen = CGRect(origin: .zero, size: Self.landscape)
        let keyboardWindow = node("window", frame: screen, children: [keyboard])
        let appWindow = node("window", frame: screen)
        let root = node("application", frame: screen, children: [appWindow, keyboardWindow])
        let converted = RunnerWindows.fullScreenTree(root, orientation: .landscapeLeft, portraitSize: Self.portrait)
        #expect(converted.children[0].frame == screen)
        #expect(converted.children[1].frame == screen)
        #expect(converted.children[1].children[0].frame == CGRect(x: 0, y: 371, width: 1133, height: 370))
        #expect(converted.children[1].children[0].children[0].frame == CGRect(x: 45, y: 467, width: 103, height: 85.5))
        let upsideDown = node("application", frame: CGRect(origin: .zero, size: Self.portrait), children: [
            node("window", frame: CGRect(origin: .zero, size: Self.portrait), children: [key])
        ])
        #expect(RunnerWindows.fullScreenTree(upsideDown, orientation: .portraitUpsideDown, portraitSize: Self.portrait)
            .children[0].children[0].frame == key.frame)
    }

    // MARK: Touching inside the window

    /// An element of a window partly off the screen is touched in its visible part, and one outside it not at all.
    @Test func selectorsResolveInsideTheWindow() {
        let window = RunnerWindowPlacement(frame: CGRect(x: -100, y: 100, width: 500, height: 500), scaleX: 1, scaleY: 1)
        var field = node("textField", frame: CGRect(x: 16, y: 34, width: 468, height: 34))
        field.identifier = "field"
        var below = node("button", frame: CGRect(x: 16, y: 600, width: 100, height: 40))
        below.identifier = "below"
        let appWindow = node("window", frame: CGRect(x: 0, y: 0, width: 500, height: 500), children: [field, below])
        let root = window.onScreen(root: node("application", frame: CGRect(x: 0, y: 0, width: 500, height: 500), children: [appWindow]),
                                   screen: Self.landscape, orientation: .portrait, portraitSize: Self.portrait)
        let screen = CGRect(origin: .zero, size: Self.landscape)
        guard case .success(let target) = RunnerElementSelector(identifier: "field").resolve(in: root, screen: screen) else {
            Issue.record("expected a target")
            return
        }
        #expect(target.point == CGPoint(x: 192, y: 151))
        guard case .failure(let failure) = RunnerElementSelector(identifier: "below").resolve(in: root, screen: screen) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.reason == .offscreen)
        // The list of what can be acted on leaves it out too.
        let listed = RunnerElementTree.interactiveElements(in: root, screen: screen)
        #expect(listed.map(\.identifier) == ["field"])
    }

    /// A Stage Manager thumbnail off the left edge of the screen can't be touched.
    @Test func aWindowOutsideTheScreenCantBeTouched() {
        let window = RunnerWindowPlacement(frame: CGRect(x: -134, y: 352, width: 111, height: 170), scaleX: 0.15, scaleY: 0.15)
        var field = node("textField", frame: CGRect(x: 16, y: 34, width: 712, height: 34))
        field.identifier = "field"
        let app = CGRect(origin: .zero, size: Self.portrait)
        let root = window.onScreen(root: node("application", frame: app, children: [node("window", frame: app, children: [field])]),
                                   screen: Self.portrait, orientation: .portrait, portraitSize: Self.portrait)
        guard case .failure(let failure) = RunnerElementSelector(identifier: "field").resolve(in: root, screen: app) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.reason == .offscreen)
    }

    // MARK: Responses

    @Test func responsesSayOnlyWhatConversionNeedsToSay() throws {
        var unchanged: [String: Any] = ["ok": true]
        RunnerWindows.annotate(&unchanged, lookup: nil)
        RunnerWindows.annotate(&unchanged, lookup: .fullScreen)
        #expect(unchanged.count == 1)
        #expect(RunnerWindows.compactWarning(lookup: nil).isEmpty)
        #expect(RunnerWindows.compactWarning(lookup: .fullScreen).isEmpty)

        var placed: [String: Any] = ["ok": true]
        RunnerWindows.annotate(&placed, lookup: .placed(RunnerWindowPlacement(
            frame: CGRect(x: 170, y: 50, width: 794, height: 530), scaleX: 0.8447, scaleY: 0.8454)))
        let window = try #require(placed["window"] as? [String: Any])
        #expect((window["x"] as? NSDecimalNumber) == 170)
        #expect((window["width"] as? NSDecimalNumber) == 794)
        #expect((window["scale"] as? NSDecimalNumber) == NSDecimalNumber(string: "0.845"))
        #expect(placed["warning"] == nil)

        var unknown: [String: Any] = ["ok": true]
        RunnerWindows.annotate(&unknown, lookup: .unknown("cannot tell"))
        #expect(unknown["window"] is NSNull)
        #expect((unknown["warning"] as? String)?.hasPrefix("cannot tell") == true)
        #expect(RunnerWindows.compactWarning(lookup: .unknown("cannot tell")).hasPrefix("warning cannot tell"))
        #expect(RunnerWindows.touchError("cannot tell").contains("nothing was sent"))
    }
}
