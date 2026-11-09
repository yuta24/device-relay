import CoreGraphics
import Foundation
@testable import Relay
import Testing

struct RunnerRemoteViewsTests {
  static let container = RunnerRemoteViews.shareSheetContainerIdentifier
  static let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

  private func node(
    _ type: String, id: String = "", label: String = "", _ frame: CGRect, _ children: [RunnerElementNode] = []
  ) -> RunnerElementNode {
    RunnerElementNode(type: type, identifier: id, label: label, value: nil, placeholder: nil, frame: frame, enabled: true,
                      selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children)
  }

  private func other(_ frame: CGRect, _ children: [RunnerElementNode] = []) -> RunnerElementNode {
    node("other", frame, children)
  }

  /// The app's tree with the share sheet as an iPhone 17 Pro simulator (iOS 27) reported it in portrait: the
  /// container at (9, 501), two host views with its frame, and the remote root at (0, 0) of its size, under
  /// which the "Copy" cell is at (20, 230) though it is drawn at (29, 731).
  private func shareSheet(at frame: CGRect, content: CGRect? = nil, extra: [RunnerElementNode] = []) -> RunnerElementNode {
    let copy = node("cell", id: "actionGroupCell", label: "Copy", CGRect(x: 19.667, y: 229.667, width: 82, height: 134.333), [
      node("image", id: "activityImageView", label: "copy", CGRect(x: 45, y: 260, width: 32, height: 38))
    ])
    let reminders = node("cell", id: "shareCell", label: "Reminders", CGRect(x: 19.667, y: 107.667, width: 82, height: 120.333))
    // A cell scrolled out of the sheet on the right.
    let scrolled = node("cell", id: "shareCell", label: "Scrolled", CGRect(x: 362.667, y: 107.667, width: 82, height: 120.333))
    let remote = other(content ?? CGRect(origin: .zero, size: frame.size), [
      node("collectionView", id: "activityCollectionView", CGRect(origin: .zero, size: frame.size), [reminders, scrolled, copy])
    ])
    let sheet = node("other", id: Self.container, frame, [other(frame, [other(frame, [remote] + extra)])])
    return node("application", Self.screen, [
      node("window", Self.screen, [
        node("button", id: "relay.behind3", label: "behind3", CGRect(x: 8, y: 425, width: 386, height: 67)),
        node("other", id: "PopoverDismissRegion", Self.screen),
        node("popover", frame, [other(frame, [node("other", id: "ActivityListView", frame, [sheet])])])
      ])
    ])
  }

  private func isNear(_ a: CGFloat, _ b: CGFloat) -> Bool {
    abs(a - b) < 0.001
  }

  private func find(_ label: String, in root: RunnerElementNode) -> RunnerElementNode? {
    if root.label == label { return root }
    for child in root.children {
      if let found = find(label, in: child) { return found }
    }
    return nil
  }

  private func container(in root: RunnerElementNode) -> RunnerElementNode? {
    if root.identifier == Self.container { return root }
    for child in root.children {
      if let found = container(in: child) { return found }
    }
    return nil
  }

  // MARK: Placement

  @Test func placesTheShareSheetAtTheContainersOrigin() throws {
    let sheet = CGRect(x: 9, y: 501, width: 384, height: 364)
    let (tree, unknown) = RunnerRemoteViews.placed(shareSheet(at: sheet))
    #expect(unknown.isEmpty)
    let copy = try #require(find("Copy", in: tree))
    #expect(isNear(copy.frame.minX, 28.667) && isNear(copy.frame.minY, 730.667))
    #expect(copy.frame.size == CGSize(width: 82, height: 134.333))
    #expect(copy.clip == sheet)
    // The icon in the screenshot is centered at about (69.5, 780).
    let icon = try #require(find("copy", in: tree))
    #expect(icon.frame.midX == 70 && icon.frame.midY == 780)
    // The container and the host views around the remote view were already on the screen.
    #expect(try #require(container(in: tree)).frame == sheet)
    #expect(try #require(container(in: tree)).children[0].frame == sheet)
    // Nothing outside the container changes.
    #expect(find("behind3", in: tree)?.frame == CGRect(x: 8, y: 425, width: 386, height: 67))
    #expect(find("behind3", in: tree)?.clip == nil)
  }

  /// Landscape (iPhone 17 Pro simulator) and an iPhone 14 Pro (iOS 26.7.1) in both orientations: the same shape,
  /// checked against screenshots.
  @Test(arguments: [
    CGRect(x: 87, y: 9, width: 699.333, height: 384),
    CGRect(x: 9, y: 480, width: 375, height: 362.667),
    CGRect(x: 85, y: 2, width: 681.667, height: 381.667)
  ])
  func placesEveryShapeTheSameWay(sheet: CGRect) throws {
    let placement = RunnerRemoteViews.placement(of: try #require(container(in: shareSheet(at: sheet))))
    #expect(placement == .offset(sheet.origin))
    let (tree, _) = RunnerRemoteViews.placed(shareSheet(at: sheet))
    let copy = try #require(find("Copy", in: tree))
    #expect(isNear(copy.frame.minX, 19.667 + sheet.minX) && isNear(copy.frame.minY, 229.667 + sheet.minY))
  }

  /// The selector touches the converted frame: the cell's center inside the sheet, not (61, 297) above it.
  @Test func aSelectorTouchesTheCellOnTheSheet() throws {
    let (tree, _) = RunnerRemoteViews.placed(shareSheet(at: CGRect(x: 9, y: 501, width: 384, height: 364)))
    let target = try RunnerElementSelector(label: "Copy", type: "cell").resolve(in: tree, screen: Self.screen).get()
    #expect(isNear(target.point.x, 69.667) && isNear(target.point.y, 730.667 + 134.333 / 2))
  }

  /// A cell scrolled out of the sheet is touched on the part inside it, or not at all: outside, the touch would
  /// close the sheet.
  @Test func aCellScrolledOutOfTheSheetIsClippedToIt() throws {
    let sheet = CGRect(x: 9, y: 501, width: 384, height: 364)
    let (tree, _) = RunnerRemoteViews.placed(shareSheet(at: sheet))
    let target = try RunnerElementSelector(label: "Scrolled").resolve(in: tree, screen: Self.screen).get()
    #expect(isNear(target.point.x, (371.667 + 393) / 2))
    let narrow = CGRect(x: 9, y: 501, width: 300, height: 364)
    let (clipped, _) = RunnerRemoteViews.placed(shareSheet(at: narrow, content: CGRect(x: 0, y: 0, width: 300, height: 364)))
    let failure = RunnerElementSelector(label: "Scrolled").resolve(in: clipped, screen: Self.screen)
    guard case .failure(let failure) = failure else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure.reason == .offscreen)
  }

  /// "More" covers the screen with the container at (0, 0): its frames already are the screen's.
  @Test func aContainerAtTheOriginNeedsNothing() throws {
    let root = shareSheet(at: Self.screen, content: CGRect(x: 0, y: 62, width: 402, height: 812))
    #expect(RunnerRemoteViews.placement(of: try #require(container(in: root))) == .inPlace)
    let (tree, unknown) = RunnerRemoteViews.placed(root)
    #expect(unknown.isEmpty)
    #expect(find("Copy", in: tree)?.frame == find("Copy", in: root)?.frame)
    #expect(find("Copy", in: tree)?.clip == nil)
  }

  /// On iPad (iOS 27 simulator) the popover's remote root is an empty element without children.
  @Test func anEmptyRemoteRootNeedsNothing() throws {
    let frame = CGRect(x: 10, y: 145, width: 375, height: 359)
    let sheet = node("other", id: Self.container, frame, [other(frame, [other(frame, [other(.zero)])])])
    #expect(RunnerRemoteViews.placement(of: sheet) == .inPlace)
    let (tree, unknown) = RunnerRemoteViews.placed(node("application", Self.screen, [sheet]))
    #expect(unknown.isEmpty)
    #expect(tree.children[0].frame == frame)
    #expect(RunnerRemoteViews.placement(of: node("other", id: Self.container, frame)) == .inPlace)
  }

  /// An empty element next to the remote root doesn't change anything.
  @Test func ignoresEmptySiblingsOfTheRemoteRoot() throws {
    let sheet = CGRect(x: 9, y: 501, width: 384, height: 364)
    let root = shareSheet(at: sheet, extra: [other(CGRect(x: 9, y: 501, width: 0, height: 0))])
    #expect(RunnerRemoteViews.placement(of: try #require(container(in: root))) == .offset(sheet.origin))
  }

  /// Frames within half a point of the container's size are the same, as the snapshot rounds to 1/3 point.
  @Test func toleratesRounding() throws {
    let sheet = CGRect(x: 87, y: 9, width: 699.2, height: 384)
    let root = shareSheet(at: sheet, content: CGRect(x: 0, y: 0, width: 699.333, height: 384))
    #expect(RunnerRemoteViews.placement(of: try #require(container(in: root))) == .offset(sheet.origin))
  }

  // MARK: Can't be placed

  /// Content of another size, or at the container's position (a system that reports screen frames, whose remote
  /// root would also be a host view): its frames are left as they are and touches at them are refused.
  @Test(arguments: [
    CGRect(x: 0, y: 0, width: 384, height: 200),
    CGRect(x: 30, y: 40, width: 384, height: 364),
    CGRect(x: 9, y: 520, width: 300, height: 300)
  ])
  func otherContentCantBePlaced(content: CGRect) throws {
    let sheet = CGRect(x: 9, y: 501, width: 384, height: 364)
    let root = shareSheet(at: sheet, content: content)
    guard case .unknown(let message) = RunnerRemoteViews.placement(of: try #require(container(in: root))) else {
      Issue.record("expected unknown")
      return
    }
    #expect(message.hasPrefix("cannot tell where the elements inside ShareSheet.RemoteContainerView (9,501,384,364) are on the screen"))
    let (tree, unknown) = RunnerRemoteViews.placed(root)
    #expect(unknown == [message])
    let copy = try #require(find("Copy", in: tree))
    #expect(copy.frame == find("Copy", in: root)?.frame)
    #expect(copy.positionUnknown == message)
    // The host views and the app's own elements can still be touched.
    #expect(try #require(container(in: tree)).positionUnknown == nil)
    #expect(find("behind3", in: tree)?.positionUnknown == nil)
  }

  @Test func aSelectorRefusesAnElementThatCantBePlaced() throws {
    let root = shareSheet(at: CGRect(x: 9, y: 501, width: 384, height: 364), content: CGRect(x: 0, y: 0, width: 384, height: 200))
    let (tree, unknown) = RunnerRemoteViews.placed(root)
    let result = RunnerElementSelector(label: "Copy", type: "cell").resolve(in: tree, screen: Self.screen)
    guard case .failure(let failure) = result else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure.reason == .positionUnknown)
    #expect(failure.isRetryable)
    #expect(failure.code == .remoteViewPositionUnknown)
    #expect(failure.message == unknown[0] + "; nothing was sent. Touch by coordinates from a screenshot instead")
    #expect(failure.json["code"] as? String == "remote_view_position_unknown")
    // Even when its frame is outside the screen: that frame says nothing.
    #expect(RunnerElementSelector(label: "Copy").resolve(in: tree, screen: .zero).failureReason == .positionUnknown)
    // Elements outside the sheet are still touched.
    #expect(RunnerElementSelector(label: "behind3").resolve(in: tree, screen: Self.screen).failureReason == nil)
  }

  // MARK: Responses

  @Test func warnsOnlyWhenSomethingCantBePlaced() {
    var body: [String: Any] = ["ok": true]
    RunnerRemoteViews.annotate(&body, unknown: [])
    #expect(body["warning"] == nil)
    #expect(RunnerRemoteViews.compactWarning(unknown: []) == "")

    RunnerRemoteViews.annotate(&body, unknown: ["cannot tell where A is"])
    #expect(body["warning"] as? String == "cannot tell where A is; those frames are not screen coordinates")
    #expect(RunnerRemoteViews.compactWarning(unknown: ["cannot tell where A is"])
      == "warning cannot tell where A is; those frames are not screen coordinates\n")

    // After the window's warning.
    var windowed: [String: Any] = ["warning": "W"]
    RunnerRemoteViews.annotate(&windowed, unknown: ["A", "B"])
    #expect(windowed["warning"] as? String == "W; A; those frames are not screen coordinates; B; those frames are not screen coordinates")
  }

  // MARK: Other conversions

  /// In an iPad window the share sheet is placed in the window first, and the window then converts its frames and
  /// its clip with the rest.
  @Test func anIPadWindowConvertsThePlacedSheetAndItsClip() throws {
    let sheet = CGRect(x: 9, y: 501, width: 384, height: 364)
    let (tree, _) = RunnerRemoteViews.placed(shareSheet(at: sheet))
    let window = RunnerWindowPlacement(frame: CGRect(x: 100, y: 50, width: 402, height: 874), scaleX: 1, scaleY: 1)
    let converted = window.onScreen(root: tree, screen: CGSize(width: 1210, height: 834), orientation: .landscapeLeft,
                                    portraitSize: CGSize(width: 834, height: 1210))
    let copy = try #require(find("Copy", in: converted))
    #expect(isNear(copy.frame.minX, 128.667) && isNear(copy.frame.minY, 780.667))
    // The sheet, cut by the bottom of the screen.
    #expect(copy.clip == CGRect(x: 109, y: 551, width: 384, height: 283))
    // Elements outside the sheet get the window's visible part.
    #expect(find("behind3", in: converted)?.clip == CGRect(x: 100, y: 50, width: 402, height: 784))
  }

  @Test func anotherDisplayConvertsTheClipToo() {
    var element = node("button", CGRect(x: 0, y: 0, width: 10, height: 20))
    element.clip = CGRect(x: 0, y: 0, width: 100, height: 200)
    let window = node("window", CGRect(x: 0, y: 0, width: 400, height: 800), [element])
    let display = RunnerDisplay(id: 1, size: CGSize(width: 400, height: 800), scale: 3, isMain: true)
    let tree = RunnerDisplays.tree(node("application", CGRect(x: 0, y: 0, width: 400, height: 800), [window]),
                                   windowDisplayIDs: [1], display: display, orientation: .landscapeLeft)
    let converted = tree.children[0].children[0]
    #expect(converted.clip.map(\.size) == CGSize(width: 200, height: 100))
    #expect(converted.clip.map { $0.contains(converted.frame) } == true)
  }
}

private extension Result where Success == RunnerElementTarget, Failure == RunnerElementLookupFailure {
  var failureReason: RunnerElementLookupFailure.Reason? {
    guard case .failure(let failure) = self else { return nil }
    return failure.reason
  }
}
