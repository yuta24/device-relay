import Foundation
@testable import Relay

func temporaryHome() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func sessionSimulator(_ name: String, _ udid: String, booted: Bool = true) -> Device {
  Device(name: name, udid: udid, kind: .simulator, os: "iOS 27.0", state: booted ? "booted" : "shutdown", isAvailable: true)
}
