import Foundation
@testable import Relay
import Testing

struct XCTestRunCaptureTests {
  /// The shape xcodebuild 27 writes for the runner (format 1), trimmed.
  private func formatOne() -> [String: Any] {
    [
      "__xctestrun_metadata__": ["ContainerInfo": ["SchemeName": "RelayRunner"], "FormatVersion": 1] as [String: Any],
      "RelayRunnerUITests": [
        "DependentProductPaths": ["__TESTROOT__/Debug-iphonesimulator/RelayRunnerHost.app"],
        "EnvironmentVariables": ["DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/x"],
        "IsUITestBundle": true,
        "PreferredScreenCaptureFormat": "screenRecording",
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "TestBundlePath": "__TESTHOST__/PlugIns/RelayRunnerUITests.xctest",
        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/RelayRunnerUITests-Runner.app",
        "UserAttachmentLifetime": "deleteOnSuccess"
      ] as [String: Any]
    ]
  }

  private func target(_ plist: [String: Any], _ name: String = "RelayRunnerUITests") -> [String: Any] {
    plist[name] as? [String: Any] ?? [:]
  }

  @Test func formatOneTurnsCaptureOffAndKeepsTheRest() throws {
    let result = try XCTestRunCapture.rewritten(formatOne(), testRoot: "/b/Build/Products")
    let runner = target(result)
    #expect(runner["PreferredScreenCaptureFormat"] as? String == "screenshots")
    #expect(runner["SystemAttachmentLifetime"] as? String == "keepNever")
    #expect(runner["UserAttachmentLifetime"] as? String == "keepNever")
    #expect(runner["IsUITestBundle"] as? Bool == true)
    #expect(runner["TestBundlePath"] as? String == "__TESTHOST__/PlugIns/RelayRunnerUITests.xctest")
    #expect(runner["TestHostPath"] as? String == "/b/Build/Products/Debug-iphonesimulator/RelayRunnerUITests-Runner.app")
    #expect(runner["DependentProductPaths"] as? [String] == ["/b/Build/Products/Debug-iphonesimulator/RelayRunnerHost.app"])
    #expect((runner["EnvironmentVariables"] as? [String: String])?["DYLD_FRAMEWORK_PATH"]
      == "/b/Build/Products/Debug-iphonesimulator:__PLATFORMS__/x")
    #expect(Set(runner.keys) == Set(target(formatOne()).keys))
    // The metadata is not a target.
    let metadata = result["__xctestrun_metadata__"] as? [String: Any]
    #expect(metadata?["PreferredScreenCaptureFormat"] == nil)
    #expect(metadata?["FormatVersion"] as? Int == 1)
  }

  @Test func addsTheKeysWhenTheTargetHasNone() throws {
    let plist: [String: Any] = ["T": ["TestHostPath": "__TESTROOT__/T.app"]]
    let result = try XCTestRunCapture.rewritten(plist, testRoot: "/p")
    #expect(target(result, "T")["SystemAttachmentLifetime"] as? String == "keepNever")
    #expect(target(result, "T")["TestHostPath"] as? String == "/p/T.app")
  }

  @Test func formatTwoRewritesEachTestTarget() throws {
    let plist: [String: Any] = [
      "__xctestrun_metadata__": ["FormatVersion": 2],
      "TestPlan": ["Name": "Plan", "IsDefault": true] as [String: Any],
      "TestConfigurations": [
        [
          "Name": "One",
          "TestTargets": [
            ["BlueprintName": "A", "PreferredScreenCaptureFormat": "screenRecording", "TestHostPath": "__TESTROOT__/A.app"],
            ["BlueprintName": "B", "SystemAttachmentLifetime": "keepAlways"]
          ]
        ] as [String: Any]
      ]
    ]
    let result = try XCTestRunCapture.rewritten(plist, testRoot: "/p")
    let configuration = (result["TestConfigurations"] as? [[String: Any]])?.first
    let targets = configuration?["TestTargets"] as? [[String: Any]] ?? []
    #expect(targets.count == 2)
    for target in targets {
      for (key, value) in XCTestRunCapture.overrides {
        #expect(target[key] as? String == value)
      }
    }
    #expect(targets.first?["TestHostPath"] as? String == "/p/A.app")
    #expect(targets.last?["BlueprintName"] as? String == "B")
    #expect(configuration?["Name"] as? String == "One")
    #expect((result["TestPlan"] as? [String: Any])?["SystemAttachmentLifetime"] == nil)
  }

  @Test func formatTwoWithoutConfigurationsIsAnError() {
    #expect(throws: SetupError.self) {
      try XCTestRunCapture.rewritten(["__xctestrun_metadata__": ["FormatVersion": 2]], testRoot: "/p")
    }
  }

  @Test func unknownFormatIsAnError() {
    #expect(throws: SetupError.self) {
      try XCTestRunCapture.rewritten(["__xctestrun_metadata__": ["FormatVersion": 3]], testRoot: "/p")
    }
  }

  @Test func writesACopyAndLeavesTheOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-xctestrun-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let products = root.appendingPathComponent("DerivedData-sim/Build/Products", isDirectory: true)
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let source = products.appendingPathComponent("RelayRunner_iphonesimulator27.2-arm64.xctestrun")
    let original = try PropertyListSerialization.data(fromPropertyList: formatOne(), format: .xml, options: 0)
    try original.write(to: source)

    let testData = RunnerLauncher.testDataURL(buildURL: root, port: 8100)
    let copy = XCTestRunCapture.url(testData: testData)
    #expect(copy.path == root.appendingPathComponent("TestData/port-8100/RelayRunner.xctestrun").path)
    try XCTestRunCapture.write(from: source, to: copy)
    // Again, over the copy the previous start left.
    try XCTestRunCapture.write(from: source, to: copy)

    #expect(try Data(contentsOf: source) == original)
    let data = try Data(contentsOf: copy)
    var format = PropertyListSerialization.PropertyListFormat.binary
    let written = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] ?? [:]
    #expect(format == .xml)
    #expect(target(written)["PreferredScreenCaptureFormat"] as? String == "screenshots")
    #expect(target(written)["TestHostPath"] as? String
      == products.standardizedFileURL.path + "/Debug-iphonesimulator/RelayRunnerUITests-Runner.app")
    #expect(!String(decoding: data, as: UTF8.self).contains(XCTestRunCapture.testRootPlaceholder))
    // Only the build's own .xctestrun is in Build/Products, so the next start selects it as before.
    #expect(try FileManager.default.contentsOfDirectory(atPath: products.path) == [source.lastPathComponent])
  }

  @Test func aSourceThatIsNotADictionaryIsAnError() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-xctestrun-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("R.xctestrun")
    try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0).write(to: source)
    #expect(throws: SetupError.self) {
      try XCTestRunCapture.write(from: source, to: root.appendingPathComponent("copy/R.xctestrun"))
    }
    #expect(throws: (any Error).self) {
      try XCTestRunCapture.write(from: root.appendingPathComponent("missing.xctestrun"), to: root.appendingPathComponent("c.xctestrun"))
    }
  }
}
