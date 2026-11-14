import Foundation
import Testing

struct RunnerJSONSourceTests {
  /// Runner-only sources aren't compiled by SwiftPM. Keep the option at each serialization site
  /// so adding a serializer or removing its slash setting fails this source check.
  @Test func runnerJSONSerializersDoNotEscapeSlashes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("Runner/RelayRunnerUITests")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .sorted { $0.path < $1.path }
    #expect(!files.isEmpty)

    var sites = 0
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for (index, line) in source.components(separatedBy: .newlines).enumerated()
        where line.contains("JSONSerialization.data") || line.contains("JSONEncoder") {
        sites += 1
        #expect(line.contains(".withoutEscapingSlashes"), "\(file.lastPathComponent):\(index + 1): specify .withoutEscapingSlashes at the JSON serialization site")
      }
    }
    #expect(sites > 0)
  }
}
