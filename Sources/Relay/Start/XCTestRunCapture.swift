import Foundation

/// The copy of the `.xctestrun` that `relay start` launches, with XCTest's screen capture turned off.
///
/// xcodebuild gives a UI test target `PreferredScreenCaptureFormat = screenRecording` and both attachment
/// lifetimes `deleteOnSuccess`. The runner is one UI test that runs until it is stopped, so testmanagerd
/// records the screen for as long as it runs. relay stop ends the test as passed, which deletes the movie,
/// but a run that fails (xcodebuild interrupted, say) keeps it in the xcresult, and simulators were found
/// holding gigabytes of such movies. Recording is `relay record`'s job, on request.
///
/// Rewriting a copy rather than the scheme reaches builds made before this change, an installed copy and a
/// `--project` runner alike, and leaves the build products (and the source hash) as they are. The copy lives
/// next to the port's test data, so `__TESTROOT__` (the directory of the `.xctestrun`) becomes the absolute
/// path of the original's directory.
enum XCTestRunCapture {
  /// The name of the copy in the port's test data directory (`RunnerLauncher.testDataURL`).
  static let fileName = "RelayRunner.xctestrun"

  /// What each test target gets. The spellings are the ones `man xcodebuild.xctestrun` and Xcode's
  /// XCTestCore use. `keepNever` drops screenshots and attachments (a spindump XCTest attaches too), not
  /// the xcresult's diagnostics (`DiagnosticCollectionPolicy`), which stay as they are.
  static let overrides: [String: String] = [
    "PreferredScreenCaptureFormat": "screenshots",
    "SystemAttachmentLifetime": "keepNever",
    "UserAttachmentLifetime": "keepNever"
  ]

  static let testRootPlaceholder = "__TESTROOT__"
  private static let metadataKey = "__xctestrun_metadata__"

  static func url(testData: URL) -> URL {
    testData.appendingPathComponent(fileName)
  }

  /// `plist` with `overrides` in every test target and `__TESTROOT__` replaced by `testRoot`. Other keys stay.
  /// Format 1 has the targets at the top level, format 2 in `TestConfigurations[].TestTargets[]`.
  static func rewritten(_ plist: [String: Any], testRoot: String) throws -> [String: Any] {
    guard let substituted = substitutingTestRoot(in: plist, with: testRoot) as? [String: Any] else {
      return plist
    }
    let metadata = substituted[metadataKey] as? [String: Any]
    let version = metadata?["FormatVersion"] as? Int ?? 1
    var result = substituted
    switch version {
    case 1:
      for (key, value) in substituted where key != metadataKey {
        if let target = value as? [String: Any] {
          result[key] = overriding(target)
        }
      }
    case 2:
      guard let configurations = substituted["TestConfigurations"] as? [Any] else {
        throw SetupError(description: "xctestrun format 2 without TestConfigurations")
      }
      result["TestConfigurations"] = configurations.map { item -> Any in
        guard var configuration = item as? [String: Any], let targets = configuration["TestTargets"] as? [Any] else {
          return item
        }
        configuration["TestTargets"] = targets.map { ($0 as? [String: Any]).map(overriding) ?? $0 }
        return configuration
      }
    default:
      throw SetupError(description: "unsupported xctestrun FormatVersion \(version)")
    }
    return result
  }

  /// Writes the rewritten copy of `source` to `destination`, in the same plist format. `source` is only read.
  static func write(from source: URL, to destination: URL) throws {
    let data = try Data(contentsOf: source)
    var format = PropertyListSerialization.PropertyListFormat.xml
    guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
      throw SetupError(description: "\(source.path) is not a dictionary")
    }
    let testRoot = source.deletingLastPathComponent().standardizedFileURL.path
    let output = try PropertyListSerialization.data(fromPropertyList: try rewritten(plist, testRoot: testRoot), format: format, options: 0)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try output.write(to: destination, options: .atomic)
  }

  private static func overriding(_ target: [String: Any]) -> [String: Any] {
    target.merging(overrides) { _, new in new }
  }

  private static func substitutingTestRoot(in value: Any, with testRoot: String) -> Any {
    switch value {
    case let string as String:
      string.replacingOccurrences(of: testRootPlaceholder, with: testRoot)
    case let dictionary as [String: Any]:
      dictionary.mapValues { substitutingTestRoot(in: $0, with: testRoot) }
    case let array as [Any]:
      array.map { substitutingTestRoot(in: $0, with: testRoot) }
    default:
      value
    }
  }
}
