import CoreGraphics
import Foundation
@testable import Relay
import Testing

/// The private hit test takes points in the portrait space. Every check that asks it (the touch check, `filter=interactive`,
/// and `hittable`) passes displayed points through `RunnerElementTree.displayedHitTest`, here with a fake hit test that
/// answers only in the portrait space, as the device did.
struct RunnerHitTestOrientationTests {
  private let portraitSize = CGSize(width: 393, height: 852)
  private static let orientations: [RunnerInterfaceOrientation] = [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]

  private func screen(_ orientation: RunnerInterfaceOrientation) -> CGRect {
    let size = orientation.isLandscape ? CGSize(width: portraitSize.height, height: portraitSize.width) : portraitSize
    return CGRect(origin: .zero, size: size)
  }

  private func node(
    _ type: String, identifier: String = "", label: String = "", frame: CGRect, children: [RunnerElementNode] = []
  ) -> RunnerElementNode {
    RunnerElementNode(
      type: type, identifier: identifier, label: label, value: nil, placeholder: nil, frame: frame,
      enabled: true, selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children
    )
  }

  private let close = CGRect(x: 20, y: 20, width: 100, height: 40)

  /// application > window > [screen: other > button Back, player: other > button Close], the player's Close exactly over
  /// the screen's Back, in displayed points.
  private func tree(_ orientation: RunnerInterfaceOrientation) -> RunnerElementNode {
    let screen = screen(orientation)
    return node("application", frame: screen, children: [
      node("window", frame: screen, children: [
        node("other", frame: screen, children: [node("button", identifier: "screen.back", label: "Back", frame: close)]),
        node("other", frame: screen, children: [node("button", identifier: "player.close", label: "Close", frame: close)])
      ])
    ])
  }

  /// The player's Close where it is in the portrait space, and the player behind everything else.
  private func portraitHitTest(_ orientation: RunnerInterfaceOrientation) -> (CGPoint) -> [Int]? {
    let a = RunnerDisplays.portraitPoint(CGPoint(x: close.minX, y: close.minY), from: orientation, portraitSize: portraitSize)
    let b = RunnerDisplays.portraitPoint(CGPoint(x: close.maxX, y: close.maxY), from: orientation, portraitSize: portraitSize)
    let portraitClose = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    return { point in portraitClose.contains(point) ? [0, 1, 0] : [0, 1] }
  }

  private func displayed(_ orientation: RunnerInterfaceOrientation) -> (CGPoint) -> [Int]? {
    RunnerElementTree.displayedHitTest(orientation: orientation, portraitSize: portraitSize, portrait: portraitHitTest(orientation))
  }

  @Test func turnsDisplayedPointsIntoThePortraitSpace() {
    let point = CGPoint(x: 10, y: 20)
    let expected: [(RunnerInterfaceOrientation, CGPoint)] = [
      (.portrait, CGPoint(x: 10, y: 20)),
      (.portraitUpsideDown, CGPoint(x: 383, y: 832)),
      (.landscapeLeft, CGPoint(x: 20, y: 842)),
      (.landscapeRight, CGPoint(x: 373, y: 10))
    ]
    for (orientation, portrait) in expected {
      var asked: [CGPoint] = []
      let hitTest = RunnerElementTree.displayedHitTest(orientation: orientation, portraitSize: portraitSize) { point in
        asked.append(point)
        return [7]
      }
      #expect(hitTest(point) == [7], "\(orientation)")
      #expect(asked == [portrait], "\(orientation)")
    }
  }

  @Test func theTouchCheckRefusesACoveredElementInEveryOrientation() throws {
    for orientation in Self.orientations {
      let root = tree(orientation)
      let back = try RunnerElementSelector(identifier: "screen.back").resolve(in: root, screen: screen(orientation)).get()
      let refused = back.verified(hitTest: displayed(orientation), in: root)
      guard case .failure(let failure) = refused else {
        Issue.record("\(orientation): the covered Back was not refused")
        continue
      }
      #expect(failure.reason == .pointCovered && failure.hit?.identifier == "player.close", "\(orientation)")
      // The element that covers it is touched as before.
      let player = try RunnerElementSelector(identifier: "player.close").resolve(in: root, screen: screen(orientation)).get()
      #expect(try player.verified(hitTest: displayed(orientation), in: root).get().point == player.point, "\(orientation)")
      // Displayed points given as they are, as before, miss the cover except in portrait.
      let unturned = back.verified(hitTest: portraitHitTest(orientation), in: root)
      #expect((try? unturned.get()) != nil || orientation == .portrait, "\(orientation)")
    }
  }

  @Test func filterInteractiveDropsACoveredControlInEveryOrientation() {
    for orientation in Self.orientations {
      let root = tree(orientation)
      let check = RunnerElementTree.interactiveHitCheck(in: root, hitTest: displayed(orientation))
      let listed = RunnerElementTree.interactiveElements(in: root, screen: screen(orientation), verifyHit: check)
      #expect(listed.map(\.identifier) == ["player.close"], "\(orientation)")
      // Unturned, the hit is the player's container, which proves nothing, so the covered Back stayed outside portrait.
      let unturned = RunnerElementTree.interactiveHitCheck(in: root, hitTest: portraitHitTest(orientation))
      let before = RunnerElementTree.interactiveElements(in: root, screen: screen(orientation), verifyHit: unturned)
      #expect(before.count == (orientation == .portrait ? 1 : 2), "\(orientation)")
    }
  }

  @Test func hittableKeepsOnlyTheCoverInEveryOrientation() {
    for orientation in Self.orientations {
      let kept = RunnerElementSelector(type: "button", visibility: .hittable)
        .allMatches(in: tree(orientation), screen: screen(orientation), hitTest: displayed(orientation))
      #expect(kept.map(\.node.identifier) == ["player.close"], "\(orientation)")
    }
  }
}
