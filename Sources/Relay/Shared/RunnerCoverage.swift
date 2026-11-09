import Foundation

/// Whether the app an element touch is for is on the screen, judged from the active applications right before
/// the touch is sent.
///
/// A permission alert, Control Center, and Notification Center are drawn by SpringBoard over the app. While one
/// is up, the accessibility client lists SpringBoard alone, yet the app's snapshot still has its elements and
/// their frames, so a touch at one of them lands on SpringBoard instead (on an alert's button, or on nothing) while
/// the runner answers `ok: true`. On iPad, every app with a window on the screen is listed, with SpringBoard, in an
/// order that need not follow the focus, so the app only has to be listed, not first. What the app draws itself or
/// shows as a remote view (in-app alerts, the share sheet, the photo picker, the keyboard) keeps it listed alone;
/// so do notification banners and the volume HUD, which this can't see.
///
/// Like `RunnerWindows.swift`, this file is compiled into both the `relay` CLI and the runner target so the SwiftPM
/// unit tests cover it; the runner only reads the active applications and SpringBoard's alert.
enum RunnerCoverage {
  /// How long a touch waits for the app to be listed again before it is refused. After the touch that dismisses
  /// an alert, SpringBoard stays listed alone for about 230 ms while the alert fades (iPhone 17 Pro simulator on
  /// iOS 27, iPhone 14 Pro on iOS 26.7.1).
  static let settleTimeout: TimeInterval = 0.4
  /// How often the active applications are read again meanwhile. One read takes 3–4 ms on a simulator and 7–9 ms
  /// on a device.
  static let pollInterval: TimeInterval = 0.05

  /// The application listed in front of `target`, or nil when the touch can go ahead: `target` is listed, it is
  /// SpringBoard (which draws over every app, so its banners and alerts are touched while another app is in front),
  /// or the list is unknown (nil: the private API is missing, the same as before this check) or holds nothing
  /// but the Dock's folder service.
  static func coveringApplication(target: String, activeBundleIDs: [String]?) -> String? {
    guard target != RunnerWindows.springboardBundleID, let activeBundleIDs, !activeBundleIDs.contains(target),
          let index = RunnerWindows.foregroundIndex(activeBundleIDs: activeBundleIDs) else { return nil }
    return activeBundleIDs[index]
  }

  /// Reads the active applications until `target` is no longer covered, for up to `timeout` seconds, and returns
  /// what still covers it then, or nil. `wait` sleeps (running the run loop) for the seconds it is given.
  static func settle(
    target: String,
    timeout: TimeInterval = settleTimeout,
    now: () -> Date = Date.init,
    wait: (TimeInterval) -> Void,
    activeBundleIDs: () -> [String]?
  ) -> String? {
    let deadline = now().addingTimeInterval(timeout)
    var covering = coveringApplication(target: target, activeBundleIDs: activeBundleIDs())
    while let current = covering {
      let remaining = deadline.timeIntervalSince(now())
      guard remaining > 0 else { return current }
      wait(min(pollInterval, remaining))
      covering = coveringApplication(target: target, activeBundleIDs: activeBundleIDs())
    }
    return nil
  }

  /// The label of the first alert in SpringBoard's tree (depth first), or nil when there is none or it has no label.
  /// Read from a snapshot of the whole tree: a query for alerts (`alerts.firstMatch`) waited about 3 s on a device
  /// when there was none, as with Control Center open.
  static func alertLabel(in root: RunnerElementNode) -> String? {
    if root.type == "alert" { return root.label.isEmpty ? nil : root.label }
    for child in root.children {
      if let label = alertLabel(in: child) { return label }
    }
    return nil
  }

  /// A touch refused because another app is in front: `foreground` is the app listed first, and `alert` the label
  /// of SpringBoard's alert when one was found (it is looked up only now, as it takes a snapshot of SpringBoard).
  struct Covered: Equatable {
    var target: String
    var foreground: String
    var alert: String?

    var message: String {
      let shown = alert.map { "an alert (\"\($0)\")" } ?? foreground
      return "\(target) is covered by \(shown); nothing was sent"
    }

    /// The error body, with `bundleId` (the app the touch was for, as in a successful answer), `foreground`, and
    /// `alert` (null when none was found).
    var json: [String: Any] {
      var object = RunnerErrorCode.coveredByOtherApp.body(message)
      object["bundleId"] = target
      object["foreground"] = foreground
      object["alert"] = alert ?? NSNull()
      return object
    }
  }
}
