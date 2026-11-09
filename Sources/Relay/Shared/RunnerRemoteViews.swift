import CoreGraphics
import Foundation

/// Views that another process draws inside the app, whose elements the app's snapshot reports in that process's
/// own coordinates instead of the screen's.
///
/// The share sheet (`UIActivityViewController`) is one: its `ShareSheet.RemoteContainerView` has a screen frame,
/// and so do the host views that wrap the remote one inside it (each repeats the container's frame). The remote
/// view's root and everything under it start again at (0, 0), relative to the container. Adding the container's
/// origin puts them on the screen, which was checked against screenshots on an iPhone 17 Pro simulator (iOS 27:
/// the card at the bottom in portrait, the card in landscape) and an iPhone 14 Pro (iOS 26.7.1, the same shapes).
/// When the container covers the screen, as for the list behind the sheet's "More", it is at (0, 0) and the
/// frames need nothing. On iPad the sheet is a popover whose remote root is an empty element, so there is nothing
/// to convert. The photo picker (`PHPickerViewController`) and `SFSafariViewController` are remote too, but report
/// screen frames, and have no such container.
///
/// Only that shape is converted. Anything else inside a known container (content of another size or elsewhere, as
/// in a later system that reports screen frames, or in the middle of an animation) can't be placed, and a touch at
/// such an element is refused instead of sent where its frame says (`RunnerElementLookupFailure.Reason`).
///
/// Like `RunnerWindows.swift`, this file is compiled into both the `relay` CLI and the runner target so the SwiftPM
/// unit tests cover it; the runner only takes the snapshot.
enum RunnerRemoteViews {
  static let shareSheetContainerIdentifier = "ShareSheet.RemoteContainerView"
  /// The identifiers of the containers whose content is converted.
  static let containerIdentifiers: Set<String> = [shareSheetContainerIdentifier]
  /// How far two frames may differ and still be the same, in points: the snapshot rounds frames to 1/3 point.
  static let tolerance: CGFloat = 0.5

  /// What a container's content needs.
  enum Placement: Equatable {
    /// Its frames already are the app's: the container is at (0, 0), or it shows nothing.
    case inPlace
    /// Its frames are relative to the container; adding `offset`, the container's origin, puts them on the screen.
    case offset(CGPoint)
    /// Its frames can't be placed; the text says why.
    case unknown(String)
  }

  /// The tree with the elements of every known container in the app's coordinates, and why those of the others
  /// could not be, one message per container (none when every container was placed). A converted element can only
  /// be touched inside its container (`clip`): one scrolled out of the sheet would otherwise be touched outside it,
  /// closing the sheet. An element that can't be placed gets `positionUnknown`.
  static func placed(_ root: RunnerElementNode) -> (tree: RunnerElementNode, unknown: [String]) {
    var unknown: [String] = []
    func visit(_ node: RunnerElementNode) -> RunnerElementNode {
      guard containerIdentifiers.contains(node.identifier) else {
        var node = node
        node.children = node.children.map(visit)
        return node
      }
      let placement = placement(of: node)
      if case .unknown(let message) = placement {
        unknown.append(message)
      }
      return contentApplying(placement, in: node)
    }
    return (visit(root), unknown)
  }

  /// What `container`'s content needs. The content is what is under the host views that repeat the container's
  /// frame; elements of no size and no children (the remote root on iPad) say nothing and are left out.
  static func placement(of container: RunnerElementNode) -> Placement {
    let frame = container.frame
    let content = hostView(of: container).children.filter { !isEmpty($0) }
    guard !content.isEmpty, !isNear(frame.origin, .zero) else { return .inPlace }
    let relative = CGRect(origin: .zero, size: frame.size)
    if content.allSatisfy({ isNear($0.frame, relative) }) {
      return .offset(frame.origin)
    }
    let frames = content.map { describe($0.frame) }.joined(separator: ", ")
    return .unknown("cannot tell where the elements inside \(container.identifier) (\(describe(frame))) are on the screen: "
      + "its content (\(frames)) is not the container's size at (0, 0)")
  }

  /// The 422 of a touch at an element that can't be placed, as for an iPad window (`RunnerWindows.touchError`).
  static func touchError(_ message: String) -> String {
    "\(message); nothing was sent. Touch by coordinates from a screenshot instead"
  }

  /// What `/find` and `/source` say when some elements could not be placed: nil when all were.
  static func warning(_ unknown: [String]) -> String? {
    unknown.isEmpty ? nil : unknown.map { "\($0); those frames are not screen coordinates" }.joined(separator: "; ")
  }

  /// Adds that to the `warning` of a `/find`, `/source`, or element touch response, after what the window
  /// already put there (`RunnerWindows.annotate`). Nothing when every element was placed.
  static func annotate(_ body: inout [String: Any], unknown: [String]) {
    guard let warning = warning(unknown) else { return }
    body["warning"] = (body["warning"] as? String).map { "\($0); \(warning)" } ?? warning
  }

  /// The line that says it at the top of `/source?format=compact`, or nothing.
  static func compactWarning(unknown: [String]) -> String {
    warning(unknown).map { "warning \($0)\n" } ?? ""
  }

  /// The innermost of the views that repeat `container`'s frame, one inside the other, starting with the container.
  private static func hostView(of container: RunnerElementNode) -> RunnerElementNode {
    var node = container
    while node.children.count == 1, isNear(node.children[0].frame, container.frame) {
      node = node.children[0]
    }
    return node
  }

  /// `container` with `placement` applied to its content (the host views stay as they are).
  private static func contentApplying(_ placement: Placement, in container: RunnerElementNode) -> RunnerElementNode {
    let change: (RunnerElementNode) -> RunnerElementNode
    switch placement {
    case .inPlace:
      return container
    case .offset(let offset):
      let clip = container.clip.map(container.frame.intersection) ?? container.frame
      change = { shifted($0, by: offset, clip: clip) }
    case .unknown(let message):
      change = { marked($0, message) }
    }
    func apply(_ node: RunnerElementNode) -> RunnerElementNode {
      var node = node
      if node.children.count == 1, isNear(node.children[0].frame, container.frame) {
        node.children = [apply(node.children[0])]
      } else {
        node.children = node.children.map { isEmpty($0) ? $0 : change($0) }
      }
      return node
    }
    return apply(container)
  }

  private static func shifted(_ node: RunnerElementNode, by offset: CGPoint, clip: CGRect) -> RunnerElementNode {
    var node = node
    node.frame = node.frame.offsetBy(dx: offset.x, dy: offset.y)
    node.clip = clip
    node.children = node.children.map { shifted($0, by: offset, clip: clip) }
    return node
  }

  private static func marked(_ node: RunnerElementNode, _ message: String) -> RunnerElementNode {
    var node = node
    node.positionUnknown = message
    node.children = node.children.map { marked($0, message) }
    return node
  }

  private static func isEmpty(_ node: RunnerElementNode) -> Bool {
    node.children.isEmpty && (node.frame.width <= 0 || node.frame.height <= 0)
  }

  private static func isNear(_ a: CGPoint, _ b: CGPoint) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
  }

  private static func isNear(_ a: CGRect, _ b: CGRect) -> Bool {
    isNear(a.origin, b.origin) && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
  }

  private static func describe(_ frame: CGRect) -> String {
    [frame.minX, frame.minY, frame.width, frame.height].map { RunnerRequestValues.decimal($0) }.joined(separator: ",")
  }
}
