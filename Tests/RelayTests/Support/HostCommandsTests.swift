import Foundation
@testable import Relay
import Testing

struct CanonicalPathTests {
    @Test func resolvesSymlinksAlsoInPathsThatDoNotExistYet() throws {
        let missing = UUID().uuidString
        #expect(URL(fileURLWithPath: "/private/tmp").canonicalFileURL.path == "/tmp")
        #expect(URL(fileURLWithPath: "/private/tmp/\(missing)/a").canonicalFileURL.path == "/tmp/\(missing)/a")
        #expect(URL(fileURLWithPath: "/tmp/\(missing)/../b").canonicalFileURL.path == "/tmp/b")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(link.appendingPathComponent("x/y").canonicalFileURL.path == real.path + "/x/y")
        #expect(URL(fileURLWithPath: "/private" + root.path).canonicalFileURL.path == root.path)
        #expect(RunnerLocator.resolve("link/x", in: URL(fileURLWithPath: "/private" + root.path)).path == real.path + "/x")
    }
}
