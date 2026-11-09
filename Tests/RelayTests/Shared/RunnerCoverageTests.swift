import Foundation
@testable import Relay
import Testing

struct RunnerCoverageTests {
  private let app = "com.example.app"
  private let springboard = RunnerWindows.springboardBundleID
  private let dockFolder = RunnerWindows.dockFolderServiceBundleID

  /// The lists seen on an iPhone 17 Pro simulator, an iPhone 14 Pro, and an iPad mini simulator in Windowed Apps mode.
  @Test func coversTheAppOnlyWhenItIsNotListed() {
    // The app in front, with its share sheet, photo picker, keyboard, or a banner over it.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [app]) == nil)
    // A permission alert, Control Center, or Notification Center.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [springboard]) == springboard)
    // iPad windows: every visible app is listed with SpringBoard, not always in the order of the focus.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [dockFolder, "com.apple.mobilesafari", app, springboard]) == nil)
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [app, springboard]) == nil)
    // SpringBoard in front after the Dock's folder.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [dockFolder, springboard]) == springboard)
  }

  /// Only SpringBoard covers: an app in front of the target is the host of a view service, or an iPad app.
  @Test func letsTouchesThroughWhenAnotherAppIsInFront() {
    // SFSafariViewController and ASWebAuthenticationSession: the host app is listed, the service that draws them isn't.
    #expect(RunnerCoverage.coveringApplication(target: "com.apple.SafariViewService", activeBundleIDs: [app]) == nil)
    // An iPad app filling the screen over the target's window.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [dockFolder, "com.apple.mobilesafari", springboard]) == nil)
    // The sign-in prompt of ASWebAuthenticationSession is SpringBoard's, and covers the service too.
    #expect(RunnerCoverage.coveringApplication(target: "com.apple.SafariViewService", activeBundleIDs: [springboard]) == springboard)
  }

  @Test func doesNotJudgeWhatItCannot() {
    // SpringBoard draws over every app, so its alerts and banners are touched while another app is listed.
    #expect(RunnerCoverage.coveringApplication(target: springboard, activeBundleIDs: [app]) == nil)
    // The private API is missing: the touch goes ahead, as before the check.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: nil) == nil)
    // Nothing but the Dock's folder service, or nothing at all.
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: [dockFolder]) == nil)
    #expect(RunnerCoverage.coveringApplication(target: app, activeBundleIDs: []) == nil)
  }

  /// A clock that only moves when `wait` is called, and lists that change with the reads.
  private final class Run {
    var time = Date(timeIntervalSince1970: 1000)
    var waits: [TimeInterval] = []
    var reads = 0
    let lists: (Int) -> [String]?

    init(_ lists: @escaping (Int) -> [String]?) { self.lists = lists }

    func settle(target: String, timeout: TimeInterval = RunnerCoverage.settleTimeout) -> String? {
      RunnerCoverage.settle(
        target: target, timeout: timeout, now: { self.time },
        wait: { self.waits.append($0); self.time.addTimeInterval($0) },
        activeBundleIDs: { self.reads += 1; return self.lists(self.reads) }
      )
    }
  }

  @Test func goesAheadAtOnceWhenTheAppIsListed() {
    let run = Run { _ in [self.app] }
    #expect(run.settle(target: app) == nil)
    #expect(run.reads == 1)
    #expect(run.waits.isEmpty)
  }

  /// After the touch that dismissed an alert, SpringBoard stays listed alone for about 230 ms.
  @Test func waitsForAnAlertThatIsLeaving() {
    let run = Run { read in read <= 5 ? [self.springboard] : [self.app] }
    #expect(run.settle(target: app) == nil)
    #expect(run.reads == 6)
    #expect(run.waits == Array(repeating: RunnerCoverage.pollInterval, count: 5))
  }

  @Test func givesUpAfterTheTimeout() {
    let run = Run { _ in [self.springboard] }
    #expect(run.settle(target: app, timeout: 0.12) == springboard)
    // 0.05 + 0.05 + the 0.02 left, then a last read at the deadline.
    #expect(run.waits.count == 3)
    #expect(abs(run.waits.reduce(0, +) - 0.12) < 1e-6)
    #expect(run.reads == 4)
  }

  /// The defaults the runner uses: the real clock and `settleTimeout`.
  @Test func settlesWithTheDefaults() {
    var waited: [TimeInterval] = []
    #expect(RunnerCoverage.settle(target: app, wait: { waited.append($0) }, activeBundleIDs: { [self.app] }) == nil)
    #expect(waited.isEmpty)
  }

  @Test func usesATimeoutWithinTheAgreedRange() {
    #expect(RunnerCoverage.settleTimeout >= 0.3 && RunnerCoverage.settleTimeout <= 0.5)
    #expect(RunnerCoverage.pollInterval < RunnerCoverage.settleTimeout)
  }

  private func node(_ type: String, _ label: String = "", _ children: [RunnerElementNode] = []) -> RunnerElementNode {
    RunnerElementNode(type: type, identifier: "", label: label, value: nil, placeholder: nil, frame: .zero, enabled: true,
                      selected: false, hasFocus: false, hasKeyboardFocus: nil, children: children)
  }

  @Test func findsTheLabelOfSpringBoardsAlert() {
    let alert = node("alert", "Allow “App” to use your location?", [node("button", "Allow Once")])
    let springboard = node("application", "SpringBoard", [node("window", "", [node("other")]), node("window", "", [node("other", "", [alert])])])
    #expect(RunnerCoverage.alertLabel(in: springboard) == "Allow “App” to use your location?")
    #expect(RunnerCoverage.alertLabel(in: alert) == "Allow “App” to use your location?")
    // Control Center and Notification Center have no alert.
    #expect(RunnerCoverage.alertLabel(in: node("application", "SpringBoard", [node("window", "", [node("button", "Power")])])) == nil)
    #expect(RunnerCoverage.alertLabel(in: node("alert")) == nil)
  }

  @Test func describesTheFailure() {
    let alert = RunnerCoverage.Covered(target: app, foreground: springboard, alert: "Allow “App” to use your location?")
    #expect(alert.message == "com.example.app is covered by an alert (\"Allow “App” to use your location?\"); nothing was sent")
    let json = alert.json
    #expect(json["ok"] as? Bool == false)
    #expect(json["code"] as? String == "covered_by_other_app")
    #expect(json["error"] as? String == alert.message)
    #expect(json["bundleId"] as? String == app)
    #expect(json["foreground"] as? String == springboard)
    #expect(json["alert"] as? String == "Allow “App” to use your location?")

    let other = RunnerCoverage.Covered(target: app, foreground: springboard, alert: nil)
    #expect(other.message == "com.example.app is covered by com.apple.springboard; nothing was sent")
    #expect(other.json["alert"] is NSNull)
  }
}
