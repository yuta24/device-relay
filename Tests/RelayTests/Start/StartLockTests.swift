import Darwin
import Foundation
@testable import Relay
import Testing

// relay start --session, and what keeps several relay starts apart. UDIDs and names are dummies.

/// Runs `body` on a thread of its own, after `delay`. Not on `DispatchQueue.global()`: a test that waits for `body`
/// blocks one of the threads Swift Testing runs tests on, which are as many as the CPUs. On a runner with 3 CPUs, three
/// such tests blocked all of them, and the global queue then got no thread to run `body` on, so none ever finished.
private func onThreadOfItsOwn(after delay: TimeInterval = 0, _ body: @escaping @Sendable () -> Void) {
  Thread.detachNewThread {
    if delay > 0 {
      Thread.sleep(forTimeInterval: delay)
    }
    body()
  }
}

struct DeviceLockTests {
  @Test func oneStartPerDevice() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let phone = sessionSimulator("iPhone 17", "sim-a")
    let lock = try StartLock.acquire(device: phone, session: "a", home: home)

    #expect {
      try StartLock.acquire(device: phone, session: "b", home: home)
    } throws: { error in
      let message = "\(error)"
      return error is DeviceInUseError && message.contains("sim-a") && message.contains("session a") && message.contains("relay stop --session a")
    }
    // The other device is free, and so is this one after the holder exits.
    let other = try StartLock.acquire(device: sessionSimulator("iPhone 17 Pro", "sim-b"), session: "b", home: home)
    other.release()
    lock.release()
    // Retried for a moment: see onceReleased.
    try onceReleased { try StartLock.acquire(device: phone, session: "b", home: home) }.release()
  }

  @Test func holderReadsPidAndSession() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let phone = sessionSimulator("iPhone 17", "SIM-A")
    let url = StartLock.deviceURL(udid: phone.udid, home: home)
    #expect(StartLock.holder(of: url) == nil)

    let lock = try StartLock.acquire(device: phone, session: "a", home: home)
    #expect(StartLock.holder(of: url) == StartLock.Holder(pid: getpid(), session: "a"))
    #expect(StartLock.devicesInUse([phone, sessionSimulator("iPhone 17 Pro", "SIM-B")], home: home) == ["SIM-A": "session a, relay start pid \(getpid())"])

    // Each check retried for a moment, as the descriptor of the one before may linger like the lock's: see onceReleased.
    lock.release()
    #expect(becomesTrue { StartLock.holder(of: url) == nil })
    #expect(becomesTrue { StartLock.devicesInUse([phone], home: home).isEmpty })
  }

  @Test func stopHintNamesTheSessionOrAnyStop() {
    #expect(StartLock.stopHint(StartLock.Holder(pid: 1, session: "a")) == "relay stop --session a")
    #expect(StartLock.stopHint(StartLock.Holder(pid: 1)) == "relay stop, or Ctrl-C where it runs")
    #expect(StartLock.stopHint(nil) == "relay stop, or Ctrl-C where it runs")
  }

  @Test func aHolderWithoutASessionStopsWithPlainRelayStop() {
    let message = StartLock.deviceHeldMessage(sessionSimulator("iPhone 17", "SIM-A"), holder: StartLock.Holder(pid: 12))
    #expect(message.contains("relay start pid 12"))
    #expect(!message.contains("--session"))
  }

  @Test func oneStartPerSession() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let lock = try StartLock.acquire(session: "a", home: home)
    #expect {
      try StartLock.acquire(session: "a", home: home)
    } throws: { "\($0)".contains("relay stop --session a") }
    try StartLock.acquire(session: "b", home: home).release()
    lock.release()
  }
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
  var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

struct AutoSelectRaceTests {
  private func commands(_ sims: [(udid: String, name: String)]) -> HostCommands {
    let entries = sims.map { #"{"udid":"\#($0.udid)","name":"\#($0.name)","state":"Booted","isAvailable":true}"# }.joined(separator: ",")
    return HostCommands(
      xcrun: { arguments, _ in
        if arguments.prefix(3) == ["simctl", "list", "devices"] {
          return #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[\#(entries)]}}"#
        }
        Issue.record("should not run: \(arguments)")
        return ""
      },
      devicectlJSON: { _, _ in Data() },
      run: { _, _, _ in "" }
    )
  }

  private func prepare(_ options: StartOptions, sims: [(udid: String, name: String)], home: URL, info: Recorder,
                       inUse: @escaping ([Device]) -> [String: String], claim: @escaping (Device) throws -> Void) throws -> StartSetup {
    try StartSetup.prepare(
      options, commands: commands(sims), configURL: home.appendingPathComponent("config.json"),
      resolveProject: { _ in (home, .option) }, staleness: { _, _ in nil }, info: { info.add($0) },
      inUse: inUse, claimDevice: claim
    )
  }

  private func busy(_ device: Device) -> DeviceInUseError {
    DeviceInUseError(device: device, holder: StartLock.Holder(pid: 7, session: "z"))
  }

  @Test func anAutomaticChoiceSelectsAgainWhenTheDeviceWasJustTaken() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let info = Recorder()
    let claims = Recorder()
    // B is in use when the first list is read, so A is the only candidate; B is free again (its holder exited)
    // when the choice is made again, and A was taken meanwhile.
    let reads = Recorder()
    let setup = try prepare(
      StartOptions(simulator: true), sims: [("SIM-A", "iPhone A"), ("SIM-B", "iPhone B")], home: home, info: info,
      inUse: { _ in
        reads.add("read")
        return reads.all.count == 1 ? ["SIM-B": "session y, relay start pid 8"] : [:]
      },
      claim: { device in
        claims.add(device.udid)
        if device.udid == "SIM-A" { throw busy(device) }
      }
    )
    #expect(setup.device.udid == "SIM-B")
    #expect(claims.all == ["SIM-A", "SIM-B"])
    #expect(info.all.contains("iPhone A was just taken by session z, relay start pid 7; selecting again"))
    #expect(info.all.filter { $0.hasPrefix("using ") }.count == 1)
    #expect(info.all.last { $0.hasPrefix("using ") }?.contains("SIM-B") == true)
  }

  @Test func theTakenDeviceStaysOutEvenIfTheLockFilesDoNotShowIt() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claims = Recorder()
    // inUse never lists A, and A is booted next to B: only the added "taken" entry keeps A out the second time.
    #expect {
      _ = try prepare(
        StartOptions(simulator: true), sims: [("SIM-A", "iPhone A"), ("SIM-B", "iPhone B")], home: home, info: Recorder(),
        inUse: { _ in ["SIM-B": "session y, relay start pid 8"] },
        claim: { device in claims.add(device.udid); throw busy(device) }
      )
    } throws: { error in
      let message = "\(error)"
      return error is SetupError && message.contains("no booted iOS simulator") && message.contains("SIM-B") && message.contains("session y")
    }
    #expect(claims.all == ["SIM-A"])
  }

  @Test func whenEveryDeviceIsTakenTheErrorListsWhoHasThem() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claims = Recorder()
    let info = Recorder()
    #expect {
      _ = try prepare(
        StartOptions(simulator: true), sims: [("SIM-A", "iPhone A")], home: home, info: info,
        inUse: { _ in [:] }, claim: { device in claims.add(device.udid); throw busy(device) }
      )
    } throws: { error in
      let message = "\(error)"
      return error is SetupError && message.contains("no booted iOS simulator") && message.contains("in use by another relay start")
        && message.contains("iPhone A") && message.contains("session z, relay start pid 7")
    }
    #expect(claims.all == ["SIM-A"])
    #expect(info.all.filter { $0.contains("selecting again") }.count == 1)
  }

  @Test func selectingAgainStopsEvenIfInUseForgetsEveryHolder() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claims = Recorder()
    // inUse forgets every holder while the claims keep failing; the devices added to the used ones end it.
    #expect(throws: SetupError.self) {
      _ = try prepare(
        StartOptions(simulator: true), sims: [("SIM-A", "iPhone A")], home: home, info: Recorder(),
        inUse: { _ in [:] }, claim: { device in claims.add(device.udid); throw busy(device) }
      )
    }
    #expect(claims.all.count <= 2)
  }

  @Test func aNamedDeviceInUseFailsAtOnce() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    for options in [StartOptions(udid: "SIM-A"), StartOptions(device: "iPhone A")] {
      let claims = Recorder()
      let info = Recorder()
      #expect {
        _ = try prepare(options, sims: [("SIM-A", "iPhone A"), ("SIM-B", "iPhone B")], home: home, info: info,
                        inUse: { _ in [:] }, claim: { device in claims.add(device.udid); throw busy(device) })
      } throws: { $0 is DeviceInUseError && "\($0)".contains("SIM-A") && "\($0)".contains("relay stop --session z") }
      #expect(claims.all == ["SIM-A"])
      #expect(!info.all.contains { $0.contains("selecting again") })
    }
  }

  @Test func otherFailuresOfTheClaimAreNotRetried() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let claims = Recorder()
    #expect {
      _ = try prepare(StartOptions(simulator: true), sims: [("SIM-A", "iPhone A")], home: home, info: Recorder(),
                      inUse: { _ in [:] }, claim: { device in claims.add(device.udid); throw SetupError(description: "cannot open lock") })
    } throws: { "\($0)" == "cannot open lock" }
    #expect(claims.all == ["SIM-A"])
  }

  @Test func aSessionTakesTheFirstOfSeveralFreeBootedSimulators() throws {
    let older = Device(name: "Alpha", udid: "SIM-0", kind: .simulator, os: "iOS 26.5", state: "booted", isAvailable: true)
    let devices = [older, sessionSimulator("beta", "SIM-3"), sessionSimulator("Alpha", "SIM-2"), sessionSimulator("alpha", "SIM-1")]
    let selection = try DeviceSelector.select(from: devices, udid: nil, name: nil, session: "race1")
    // Newest iOS first, then the name without case, then the UDID.
    #expect(selection.device.udid == "SIM-1")
    #expect(selection.isAutomatic)
    #expect(selection.reason == "the first of 4 free booted simulators (newest iOS, then name), for session race1")
    // A device in use is not among them.
    #expect(try DeviceSelector.select(from: devices, udid: nil, name: nil, inUse: ["SIM-1": "x"], session: "race1").device.udid == "SIM-2")
    // Without a session it stays an error.
    #expect { try DeviceSelector.select(from: devices, udid: nil, name: nil) } throws: { "\($0)".contains("4 simulators are booted") }
    // --udid and --device keep their meaning.
    #expect(try DeviceSelector.select(from: devices, udid: "SIM-3", name: nil, session: "race1").device.udid == "SIM-3")
  }

  @Test func connectedDevicesAreNeverGuessedForASession() {
    func phone(_ name: String, _ udid: String) -> Device {
      Device(name: name, udid: udid, kind: .device, os: "iOS 26.0", state: "connected", isAvailable: true)
    }
    let devices = [phone("One", "D-1"), phone("Two", "D-2"), sessionSimulator("iPhone", "SIM-1")]
    #expect { try DeviceSelector.select(from: devices, udid: nil, name: nil, session: "race1") } throws: { "\($0)".contains("2 devices are connected") }
  }

  @Test func twoSessionsOnTwoBootedSimulatorsEndUpOnDifferentOnes() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sims = [("SIM-A", "iPhone A"), ("SIM-B", "iPhone B")]
    // Both read the lock files before either claims. The first claims A; the second finds A taken and selects B.
    let first = try prepare(StartOptions(simulator: true, session: "race1"), sims: sims, home: home, info: Recorder(),
                            inUse: { StartLock.devicesInUse($0, home: home) },
                            claim: { _ = try StartLock.acquire(device: $0, session: "race1", home: home) })
    #expect(first.device.udid == "SIM-A")
    let info = Recorder()
    let second = try prepare(StartOptions(simulator: true, session: "race2"), sims: sims, home: home, info: info,
                             inUse: { _ in [:] },
                             claim: { _ = try StartLock.acquire(device: $0, session: "race2", home: home) })
    #expect(second.device.udid == "SIM-B")
    #expect(info.all.contains { $0.hasPrefix("iPhone A was just taken by session race1") })
    // A third finds none left.
    #expect {
      _ = try prepare(StartOptions(simulator: true, session: "race3"), sims: sims, home: home, info: Recorder(),
                      inUse: { StartLock.devicesInUse($0, home: home) }, claim: { _ in Issue.record("nothing to claim") })
    } throws: { "\($0)".contains("no booted iOS simulator") }
  }

  @Test func theErrorShowsLikeTheOldOne() {
    let phone = sessionSimulator("iPhone 17", "SIM-A")
    let holder = StartLock.Holder(pid: 12, session: "a")
    #expect(DeviceInUseError(device: phone, holder: holder).description == StartLock.deviceHeldMessage(phone, holder: holder))
  }

  @Test func twoThreadsClaimingOneDeviceGetOneLock() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let phone = sessionSimulator("iPhone 17", "sim-a")
    let results = Recorder()
    let group = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    let held = Locked<[StartLock]>([])
    for index in 0 ..< 8 {
      group.enter()
      onThreadOfItsOwn {
        start.wait()
        do {
          let lock = try StartLock.acquire(device: phone, session: "s\(index)", home: home)
          held.withLock { $0.append(lock) }
          results.add("won")
        } catch is DeviceInUseError {
          results.add("busy")
        } catch {
          results.add("other: \(error)")
        }
        group.leave()
      }
    }
    for _ in 0 ..< 8 { start.signal() }
    group.wait()
    #expect(results.all.filter { $0 == "won" }.count == 1)
    #expect(results.all.filter { $0 == "busy" }.count == 7)
    held.value.forEach { $0.release() }
  }

  @Test func aRealLockHeldByAnotherStartIsSkippedForTheNextDevice() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sims = [("SIM-A", "iPhone A"), ("SIM-B", "iPhone B")]
    // Another start holds A after this one read the lock files (inUse reads nothing at first), and B is free later.
    let held = try StartLock.acquire(device: sessionSimulator("iPhone A", "SIM-A"), session: "other", home: home)
    defer { held.release() }
    let reads = Recorder()
    let info = Recorder()
    let setup = try prepare(
      StartOptions(simulator: true), sims: sims, home: home, info: info,
      inUse: { devices in
        reads.add("read")
        // The first read happens before the other start's claim: only B shows as used (by a start that then exits).
        return reads.all.count == 1 ? ["SIM-B": "session y, relay start pid 8"] : StartLock.devicesInUse(devices, home: home).filter { $0.key != "SIM-B" }
      },
      claim: { _ = try StartLock.acquire(device: $0, session: "mine", home: home) }
    )
    #expect(setup.device.udid == "SIM-B")
    #expect(info.all.contains { $0.hasPrefix("iPhone A was just taken by session other, relay start pid \(getpid())") })
  }
}

struct BuildLockTests {
  private func makeLock(_ home: URL) throws -> BuildLock {
    try BuildLock(derivedData: home.appendingPathComponent("DerivedData-sim"), relayDirectory: home.appendingPathComponent(".relay"))
  }

  @Test func aDerivedDataHasOneLockFile() {
    let relay = URL(fileURLWithPath: "/h/.relay", isDirectory: true)
    let sim = BuildLock.url(derivedData: URL(fileURLWithPath: "/h/.relay/build/a/DerivedData-sim"), relayDirectory: relay)
    #expect(sim.deletingLastPathComponent().path == "/h/.relay/locks")
    #expect(sim.lastPathComponent.hasPrefix("build-"))
    #expect(sim != BuildLock.url(derivedData: URL(fileURLWithPath: "/h/.relay/build/a/DerivedData-device"), relayDirectory: relay))
  }

  @Test func sharedHoldersRunSideBySide() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let first = try makeLock(home)
    let second = try makeLock(home)
    defer {
      first.release()
      second.release()
    }
    #expect(try first.wait(for: .shared, info: { _ in }) == false)
    #expect(try second.wait(for: .shared, info: { _ in }) == false)
  }

  @Test func anExclusiveHolderMakesOthersWaitAndSaysSo() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let builder = try makeLock(home)
    try builder.wait(for: .exclusive, info: { _ in })
    let waiter = try makeLock(home)
    defer { waiter.release() }

    // Released from another thread once the waiter has said that it waits.
    var lines: [String] = []
    let waited = try waiter.wait(for: .shared, isCancelled: { false }, info: { line in
      lines.append(line)
      onThreadOfItsOwn(after: 0.05) { builder.release() }
    })
    #expect(waited)
    #expect(lines.count == 1)
    #expect(lines[0].contains("waiting for another relay start's build"))
  }

  @Test func aBuildWaitsForAStartLaunchingFromTheProducts() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let launching = try makeLock(home)
    try launching.wait(for: .shared, info: { _ in })
    let builder = try makeLock(home)
    defer { builder.release() }
    let waited = try builder.wait(for: .exclusive, isCancelled: { false }, info: { _ in
      onThreadOfItsOwn(after: 0.05) { launching.release() }
    })
    #expect(waited)
  }

  /// `body` on a thread of its own, since waiting for the lock polls. `join` returns what it returned.
  private final class Waiter: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Bool, Error>?
    private let waitingSignal = DispatchSemaphore(value: 0)

    init(_ buildLock: BuildLock, deadline: Date) {
      let thread = Thread { [self] in
        let result = Result {
          try buildLock.wait(for: .exclusive, isCancelled: { Date() > deadline }, info: { [self] _ in waitingSignal.signal() })
        }
        lock.withLock { self.result = result }
        done.signal()
      }
      thread.start()
    }

    /// Returns once the thread has said that it waits, or by the time limit.
    func waitUntilPolling(timeout: TimeInterval) -> Bool {
      waitingSignal.wait(timeout: .now() + timeout) == .success
    }

    var hasFinished: Bool { lock.withLock { result != nil } }

    func join() throws -> Bool {
      done.wait()
      return try lock.withLock { result! }.get()
    }
  }

  // On Darwin a failed LOCK_EX | LOCK_NB keeps the shared lock: two starts that both held it shared and
  // both decided to build would each block the other for ever. The limit turns that into a failure here.
  @Test func twoStartsHoldingItSharedCanBothGoOnToBuild() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let first = try makeLock(home)
    let second = try makeLock(home)
    defer {
      first.release()
      second.release()
    }
    try first.wait(for: .shared, info: { _ in })
    try second.wait(for: .shared, info: { _ in })

    let deadline = Date().addingTimeInterval(3)
    let waiter = Waiter(second, deadline: deadline)
    #expect(waiter.waitUntilPolling(timeout: 3))

    // The other one gets it, and the waiter does not get it at the same time.
    try first.wait(for: .exclusive, isCancelled: { Date() > deadline }, info: { _ in })
    Thread.sleep(forTimeInterval: BuildLock.pollInterval * 2)
    #expect(!waiter.hasFinished)

    first.release()
    #expect(try waiter.join())
  }

  @Test func aBuilderGoesBackToSharedWithoutLettingABuildIn() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let builder = try makeLock(home)
    let reader = try makeLock(home)
    let nextBuilder = try makeLock(home)
    defer {
      builder.release()
      reader.release()
      nextBuilder.release()
    }
    try builder.wait(for: .exclusive, info: { _ in })

    let waiter = Waiter(nextBuilder, deadline: Date().addingTimeInterval(5))
    #expect(waiter.waitUntilPolling(timeout: 3))

    // Nothing holds it against the builder, so this does not wait; a reader then joins it.
    #expect(try builder.wait(for: .shared, isCancelled: { true }, info: { _ in }) == false)
    #expect(try reader.wait(for: .shared, isCancelled: { true }, info: { _ in }) == false)
    Thread.sleep(forTimeInterval: BuildLock.pollInterval * 2)
    #expect(!waiter.hasFinished)

    // A build gets in only once nobody reads the products any more.
    builder.release()
    reader.release()
    #expect(try waiter.join())
  }

  @Test func waitingCanBeCancelled() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let builder = try makeLock(home)
    defer { builder.release() }
    try builder.wait(for: .exclusive, info: { _ in })
    let waiter = try makeLock(home)
    defer { waiter.release() }
    #expect(throws: SetupError.self) {
      try waiter.wait(for: .shared, isCancelled: { true }, info: { _ in })
    }
  }
}

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct StartLockTests {
  private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func oneStartPerPort() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let lock = try StartLock.acquire(port: 8100, home: home)
    #expect(StartLock.url(port: 8100, home: home).path == home.path + "/.relay/locks/start-8100.lock")

    // flock is per open file, so a second acquire in this process is refused like one in another process.
    #expect {
      try StartLock.acquire(port: 8100, home: home)
    } throws: { error in
      let message = String(describing: error)
      return error is SetupError && message.contains("(pid \(getpid())) is starting or running a runner on port 8100")
        && message.contains("--port")
    }
    // Another port is another lock.
    let other = try StartLock.acquire(port: 8101, home: home)
    other.release()

    lock.release()
    // Retried for a moment: see onceReleased.
    try onceReleased { try StartLock.acquire(port: 8100, home: home) }.release()
  }

  @Test func aLeftoverLockFileDoesNotBlock() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let url = StartLock.url(port: 8100, home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Left by a relay start that was killed; the kernel released its lock.
    try "99999999\n".write(to: url, atomically: true, encoding: .utf8)

    let lock = try StartLock.acquire(port: 8100, home: home)
    defer { lock.release() }
    #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")
  }

  @Test func theDetachedStartKeepsTheLockItInherits() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let lock = try StartLock.acquire(port: 8100, home: home)
    defer { lock.release() }
    let environment = [StartLock.inheritedEnvironmentKey: "\(lock.fileDescriptor)"]

    #expect(StartLock.inherited(port: 8100, home: home, environment: environment)?.fileDescriptor == lock.fileDescriptor)
    #expect(fcntl(lock.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    // Not the lock for another port, and not a descriptor of the file that does not hold the lock.
    try StartLock.acquire(port: 8101, home: home).release()
    #expect(StartLock.inherited(port: 8101, home: home, environment: environment) == nil)
    let unlocked = open(StartLock.url(port: 8100, home: home).path, O_RDONLY)
    defer { close(unlocked) }
    #expect(StartLock.inherited(port: 8100, home: home, environment: [StartLock.inheritedEnvironmentKey: "\(unlocked)"]) == nil)
    #expect(StartLock.inherited(port: 8100, home: home, environment: [:]) == nil)
  }

  @Test func theMessageLeavesOutAnUnknownOwner() {
    #expect(StartLock.heldMessage(port: 8100, owner: nil).hasPrefix("another relay start is starting or running a runner on port 8100, "))
  }
}
