import Foundation
@testable import Relay
import Testing

// relay record (simulators, and devices connected with USB). UDIDs, names, and paths are dummies.

struct DeviceCaptureTests {
  func device(state: String = "connected", available: Bool = true, transport: String? = "wired") -> Device {
    Device(name: "Test Phone", udid: "00000000-0000000000000001", kind: .device, os: "iOS 26.0", state: state,
           isAvailable: available, transport: transport)
  }

  @Test func aDeviceMustBeConnectedWithUSB() throws {
    #expect(DeviceCapture.connectionProblem(device()) == nil)
    // devicectl may not report the transport; the capture device then tells.
    #expect(DeviceCapture.connectionProblem(device(transport: nil)) == nil)
    let wifi = try #require(DeviceCapture.connectionProblem(device(transport: "localNetwork")))
    #expect(wifi.contains("over the network only (localNetwork)"))
    #expect(wifi.contains("USB cable"))
    let unplugged = try #require(DeviceCapture.connectionProblem(device(state: "unavailable", available: false, transport: nil)))
    #expect(unplugged == "the device Test Phone (00000000-0000000000000001) is not connected (unavailable); "
      + "recording a device needs it connected with a USB cable and unlocked")
  }

  @Test func cameraAccessIsNeeded() throws {
    #expect(DeviceCapture.accessProblem(.authorized) == nil)
    // Asked for before it counts.
    #expect(DeviceCapture.accessProblem(.notDetermined) == nil)
    let denied = try #require(DeviceCapture.accessProblem(.denied))
    #expect(denied.contains("System Settings > Privacy & Security > Camera"))
    #expect(denied.contains("restart it"))
    #expect(try #require(DeviceCapture.accessProblem(.restricted)).contains("restricted"))
  }

  @Test func theScreenIsFoundByTheDeviceName() {
    let candidates = [
      DeviceCapture.Candidate(uniqueID: "AAAAAAAA-0000-0000-0000-000000000001", name: "Test Phone"),
      DeviceCapture.Candidate(uniqueID: "AAAAAAAA-0000-0000-0000-000000000002", name: "Test Pad")
    ]
    #expect(DeviceCapture.match(name: "Test Phone", candidates: candidates) == .found(uniqueID: "AAAAAAAA-0000-0000-0000-000000000001"))
    #expect(DeviceCapture.match(name: "Test Pad", candidates: candidates) == .found(uniqueID: "AAAAAAAA-0000-0000-0000-000000000002"))
    #expect(DeviceCapture.match(name: "Test Pod", candidates: candidates) == .notFound)
    #expect(DeviceCapture.match(name: "Test Phone", candidates: []) == .notFound)
    let twins = candidates + [DeviceCapture.Candidate(uniqueID: "AAAAAAAA-0000-0000-0000-000000000003", name: "Test Phone")]
    #expect(DeviceCapture.match(name: "Test Phone", candidates: twins) == .ambiguous(count: 2))
    #expect(DeviceCapture.ambiguousMessage(name: "Test Phone", count: 2).hasPrefix("2 connected devices are named \"Test Phone\""))
  }

  @Test func theKindOfApostropheDoesNotMatter() {
    let curly = [DeviceCapture.Candidate(uniqueID: "A1", name: "Kim\u{2019}s iPhone")]
    #expect(DeviceCapture.match(name: "Kim's iPhone", candidates: curly) == .found(uniqueID: "A1"))
    let straight = [DeviceCapture.Candidate(uniqueID: "A2", name: "Kim's iPhone")]
    #expect(DeviceCapture.match(name: "Kim\u{2019}s iPhone", candidates: straight) == .found(uniqueID: "A2"))
    let quoted = [DeviceCapture.Candidate(uniqueID: "A3", name: "\u{201C}Lab\u{201D} Phone")]
    #expect(DeviceCapture.match(name: "\"Lab\" Phone", candidates: quoted) == .found(uniqueID: "A3"))
  }

  @Test func caseAndAccentsDoNotMatter() {
    let candidates = [DeviceCapture.Candidate(uniqueID: "A1", name: "Zoë's iPhone")]
    #expect(DeviceCapture.match(name: "zoë's iphone", candidates: candidates) == .found(uniqueID: "A1"))
    #expect(DeviceCapture.match(name: "Zoe's iPhone", candidates: candidates) == .found(uniqueID: "A1"))
    #expect(DeviceCapture.match(name: "ZOE\u{2019}S IPHONE", candidates: candidates) == .found(uniqueID: "A1"))
    #expect(DeviceCapture.match(name: "Zoe's iPad", candidates: candidates) == .notFound)
  }

  @Test func anExactMatchComesFirst() {
    let candidates = [
      DeviceCapture.Candidate(uniqueID: "A1", name: "Test Phone"),
      DeviceCapture.Candidate(uniqueID: "A2", name: "test phone")
    ]
    #expect(DeviceCapture.match(name: "Test Phone", candidates: candidates) == .found(uniqueID: "A1"))
    #expect(DeviceCapture.match(name: "test phone", candidates: candidates) == .found(uniqueID: "A2"))
    // Without an exact match both are as close.
    #expect(DeviceCapture.match(name: "TEST PHONE", candidates: candidates) == .ambiguous(count: 2))
    let apostrophes = [
      DeviceCapture.Candidate(uniqueID: "B1", name: "Kim\u{2019}s iPhone"),
      DeviceCapture.Candidate(uniqueID: "B2", name: "kim's iphone")
    ]
    #expect(DeviceCapture.match(name: "Kim's iPhone", candidates: apostrophes) == .ambiguous(count: 2))
  }

  @Test func aGapInTheFramesIsNotedOnceUntilTheyComeAgain() throws {
    var watch = FrameWatch()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    // Nothing before the first frame: record start waits for that.
    #expect(watch.check(lastFrame: nil, now: start.addingTimeInterval(60)) == nil)
    #expect(watch.check(lastFrame: start, now: start.addingTimeInterval(4.9)) == nil)
    let note = watch.check(lastFrame: start, now: start.addingTimeInterval(5))
    let stalled = try #require(note)
    #expect(stalled.hasPrefix("no frame for 5s (the device may be locked, or the capture stalled); still recording"))
    // What record status looks for in the log.
    #expect("relay: \(stalled)".hasPrefix(DeviceCapture.stallMarker))
    #expect(watch.stalledSince == start)
    // Once.
    #expect(watch.check(lastFrame: start, now: start.addingTimeInterval(30)) == nil)
    let resumed = watch.check(lastFrame: start.addingTimeInterval(12.4), now: start.addingTimeInterval(12.5))
    #expect(resumed == "frames came again after 12s without one")
    #expect("relay: \(resumed ?? "")".hasPrefix(DeviceCapture.resumeMarker))
    #expect(watch.stalledSince == nil)
    // And again for the next gap.
    #expect(watch.check(lastFrame: start.addingTimeInterval(12.4), now: start.addingTimeInterval(17.5)) != nil)
  }

  @Test func aNewProcessIsTriedOnlyWhenNoScreenShowedUp() {
    let none = "relay: recording the device in pid 6160\nrelay: " + DeviceCapture.notFoundMessage(name: "Test Phone", candidates: []) + "\n"
    #expect(DeviceCapture.noScreenShowedUp(inLog: none))
    // Another device's screen did: the name is wrong, and a new process would not see it either.
    let others = "relay: " + DeviceCapture.notFoundMessage(name: "Test Phone", candidates: [DeviceCapture.Candidate(uniqueID: "A", name: "Test Pad")])
    #expect(!DeviceCapture.noScreenShowedUp(inLog: others))
    #expect(!DeviceCapture.noScreenShowedUp(inLog: "relay: " + DeviceCapture.ambiguousMessage(name: "Test Phone", count: 2)))
    #expect(!DeviceCapture.noScreenShowedUp(inLog: "relay: recording the device in pid 6160\nRecording started\n"))
    // The end is the second supervisor's.
    let retried = none + "relay: recording the device in pid 6170\nRecording started\nrelay: reached --max-duration of 5s; stopped the recording\n"
    #expect(Recording.endReason(inLog: retried) == "reached --max-duration of 5s; stopped the recording")
    // The wait after a capture covers the window in which a new process would not see the screen.
    #expect(DeviceCapture.releaseDelay >= 3)
  }

  @Test func notFoundSaysWhatToDo() {
    let none = DeviceCapture.notFoundMessage(name: "Test Phone", candidates: [])
    #expect(none.contains("no device screen is available"))
    #expect(none.contains("USB cable"))
    #expect(none.contains("unlock it"))
    #expect(none.contains("wait a minute"))
    let others = DeviceCapture.notFoundMessage(name: "Test Phone", candidates: [DeviceCapture.Candidate(uniqueID: "A", name: "Test Pad")])
    #expect(others.contains("the screens available are \"Test Pad\""))
  }

  @Test func movieOnlyForMov() {
    #expect(DeviceCapture.fileType(forPath: "/tmp/a.mp4") == .mp4)
    #expect(DeviceCapture.fileType(forPath: "/tmp/a") == .mp4)
    #expect(DeviceCapture.fileType(forPath: "/tmp/a.MOV") == .mov)
    #expect(DeviceCapture.fileType(forPath: "/tmp/a.m4v") == .m4v)
  }
}
