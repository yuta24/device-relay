import Foundation

/// What the host's tools say about an app on the runner's device.
enum AppInstallState: Equatable {
  case installed
  case notInstalled
  /// The tools can't tell, or aren't asked. The app is sent to the runner, as if there were no check; a
  /// reason is shown to people, and nil is the expected case that needs no line (a system app on a device).
  case unknown(reason: String?)
}

/// The host's tools `AppInstallCheck` asks. Tests replace them with canned output.
struct AppInstallProbe: Sendable {
  /// `xcrun <args>`; stdout and stderr merged. Throws `ShellError` on a nonzero status.
  var xcrun: @Sendable ([String]) throws -> String
  /// `xcrun devicectl <args> --json-output <file>`, returning the JSON document devicectl wrote.
  var devicectlJSON: @Sendable ([String]) throws -> Data

  static let live = AppInstallProbe(
    xcrun: { try Shell.xcrun($0, timeout: AppInstallCheck.simctlTimeout) },
    devicectlJSON: { try HostCommands.devicectlJSON($0, timeout: AppInstallCheck.devicectlTimeout) }
  )
}

/// Checks that an app is installed before `/launch` is sent.
///
/// XCTest takes about five minutes to give up on an app that isn't installed (298 s on a simulator, with
/// the runner busy all that time), and nothing the runner can reach tells it sooner. The host can: `simctl`
/// and `devicectl` answer in under a second once their service runs.
///
/// A wrong "not installed" would refuse an app that works, while a wrong "installed" only costs the old
/// wait. So only an answer that says so outright counts, and anything else is `unknown` and is sent.
enum AppInstallCheck {
  /// The `code` of the JSON relay prints for an app that isn't installed. relay answers this itself; the
  /// runner never does, so it is not a `RunnerErrorCode` (see `RelayErrorCode`). Never rename it.
  static let notInstalledCode = RelayErrorCode.appNotInstalled.rawValue

  /// `simctl get_app_container` took about 0.3 s.
  static let simctlTimeout: TimeInterval = 5
  /// `devicectl` took about 0.3 s on a simulator and 3 s when its service had to start first.
  static let devicectlTimeout: TimeInterval = 10

  /// Apps seen installed by this process, as `<udid> <bundle ID>`, so a `relay run` with several launches
  /// of one app asks once. Nothing in a scenario can uninstall an app.
  private static let seenInstalled = Locked<Set<String>>([])

  /// The check `RunnerControl` makes before `/launch`. `hostBundleID` is known to be installed: the runner
  /// runs from it.
  static func state(of bundleID: String, udid: String, hostBundleID: String?, probe: AppInstallProbe = .live) -> AppInstallState {
    if bundleID == hostBundleID {
      return .installed
    }
    let key = "\(udid) \(bundleID)"
    if seenInstalled.value.contains(key) {
      return .installed
    }
    let state = ask(bundleID: bundleID, udid: udid, probe: probe)
    if state == .installed {
      seenInstalled.withLock { _ = $0.insert(key) }
    }
    return state
  }

  /// `simctl` first, as it also tells whether the UDID is a simulator; `devicectl` for a device.
  static func ask(bundleID: String, udid: String, probe: AppInstallProbe) -> AppInstallState {
    let answer: SimctlAnswer
    do {
      answer = interpretSimctl(status: 0, output: try probe.xcrun(["simctl", "get_app_container", udid, bundleID]))
    } catch let error as ShellError {
      answer = error.timeoutDetail.map { .state(.unknown(reason: "simctl \($0)")) }
        ?? interpretSimctl(status: error.status, output: error.output)
    } catch {
      answer = .state(.unknown(reason: "simctl did not run: \(error)"))
    }
    if case .state(let state) = answer {
      return state
    }
    if isSystemApp(bundleID) {
      return .unknown(reason: nil)
    }
    do {
      return interpretDevicectl(try probe.devicectlJSON(devicectlArguments(bundleID: bundleID, udid: udid)), bundleID: bundleID)
    } catch let error as ShellError {
      return .unknown(reason: "devicectl \(error.timeoutDetail ?? "failed (\(error.status))")")
    } catch {
      return .unknown(reason: "devicectl did not run: \(error)")
    }
  }

  enum SimctlAnswer: Equatable {
    case state(AppInstallState)
    case notASimulator
  }

  /// `simctl get_app_container <udid> <id>` prints the app's path and exits 0, also for system apps (Safari,
  /// Settings, SpringBoard). It exits 2 with `domain=NSPOSIXErrorDomain, code=2` for an app that isn't
  /// installed and 148 with `Invalid device` for a UDID that isn't a simulator. Others, such as 149 for a
  /// simulator that is shut down, say nothing about the app.
  static func interpretSimctl(status: Int32, output: String) -> SimctlAnswer {
    if status == 0 {
      return .state(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .unknown(reason: "simctl printed no path")
        : .installed)
    }
    if status == 2, output.contains("domain=NSPOSIXErrorDomain, code=2") {
      return .state(.notInstalled)
    }
    if status == 148 || output.contains("Invalid device") {
      return .notASimulator
    }
    return .state(.unknown(reason: "simctl failed (\(status))"))
  }

  /// `--include-all-apps` is needed: `--bundle-id` alone looks at developer apps only, and finds no Safari.
  /// It still narrows the list to `--bundle-id`.
  static func devicectlArguments(bundleID: String, udid: String) -> [String] {
    ["device", "info", "apps", "--device", udid, "--include-all-apps", "--bundle-id", bundleID]
  }

  /// `result.apps` of the JSON document. An empty list counts only from a run that says it looked at
  /// default, removable, hidden, and internal apps (all four were true on a device and on a simulator); a
  /// devicectl that reports otherwise or leaves one out, or a document of another shape, says nothing about the app.
  static func interpretDevicectl(_ data: Data, bundleID: String) -> AppInstallState {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          (root["info"] as? [String: Any])?["outcome"] as? String == "success",
          let result = root["result"] as? [String: Any],
          let apps = result["apps"] as? [[String: Any]] else {
      return .unknown(reason: "unexpected devicectl output")
    }
    if apps.contains(where: { $0["bundleIdentifier"] as? String == bundleID }) {
      return .installed
    }
    let listedEveryApp = ["defaultAppsIncluded", "removableAppsIncluded", "hiddenAppsIncluded", "internalAppsIncluded"]
      .allSatisfy { result[$0] as? Bool == true }
    guard listedEveryApp else {
      return .unknown(reason: "devicectl did not list every app")
    }
    return .notInstalled
  }

  /// On a device a system app need not be listed (SpringBoard, say, is not meant to be launched by name),
  /// and it can't be installed by mistake, so it isn't looked up. A system app the user removed takes
  /// the long wait, as before.
  static func isSystemApp(_ bundleID: String) -> Bool {
    bundleID.lowercased().hasPrefix("com.apple.")
  }

  /// What relay prints instead of sending `/launch` or `/open`: the same JSON a failure from the runner has, for
  /// stdout (see `RunnerControl`); the `relay:` line of `notInstalledHint` goes to stderr.
  static func notInstalledBody(bundleID: String, device: String) -> Data {
    CLIOutput.failureBody(.appNotInstalled, "\(bundleID) is not installed on \(device)")
  }

  static func notInstalledHint(bundleID: String, device: String) -> String {
    "\(bundleID) is not installed on \(device); nothing was sent to the runner. Check the bundle ID, or install the app first (relay launch and relay open --bundle-id only reach installed apps)"
  }

  /// `waits`: the runner holds on for minutes when the app is missing (`/launch`), rather than failing at once (`/open`).
  static func uncheckedHint(bundleID: String, reason: String, waits: Bool = true) -> String {
    "cannot tell whether \(bundleID) is installed (\(reason)); sending it to the runner"
      + (waits ? ", which waits for minutes if it is not" : "")
  }
}
