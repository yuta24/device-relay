import Foundation
@testable import Relay
import Testing

struct RunnerProjectTests {
  /// <root>/relay (a checkout with the project), <root>/relay/bin/relay -> <root>/relay/.build/relay,
  /// <root>/links/relay -> the same, and <root>/app/sub (the current directory).
  private struct Tree {
    let root: URL
    var checkout: URL { root.appendingPathComponent("relay") }
    var current: URL { root.appendingPathComponent("app/sub") }
    var executable: URL { checkout.appendingPathComponent(".build/release/relay") }
    var link: URL { root.appendingPathComponent("links/relay") }

    init() throws {
      root = try temporaryDirectory()
      let manager = FileManager.default
      try manager.createDirectory(at: checkout.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
      try manager.createDirectory(at: current, withIntermediateDirectories: true)
      try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      manager.createFile(atPath: executable.path, contents: Data())
      try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    var home: URL { root.appendingPathComponent("home") }

    func resolve(_ explicitPath: String? = nil, environment: [String: String] = [:], current: URL? = nil, executable: URL? = nil,
                 includeInstalled: Bool = true) throws -> (root: URL, source: RunnerProject.Source) {
      try RunnerProject.resolve(explicitPath: explicitPath, environment: environment, currentDirectory: current ?? self.current,
                                executableURL: executable, home: home, includeInstalled: includeInstalled)
    }
  }

  @Test func prefersOptionThenEnvironmentThenCurrentDirectoryThenExecutable() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let environment = [RunnerProject.environmentKey: tree.checkout.path]

    // Relative to the current directory; the .xcodeproj path works too.
    #expect(try tree.resolve("../../relay", environment: ["RELAY_HOME": "/nonexistent"]) == (tree.checkout, .option))
    #expect(try tree.resolve(tree.checkout.appendingPathComponent(RunnerProject.projectPath).path).root == tree.checkout)
    #expect(try tree.resolve(tree.checkout.appendingPathComponent("Runner").path).root == tree.checkout)
    #expect(try tree.resolve(environment: environment) == (tree.checkout, .environment))
    #expect(try tree.resolve(current: tree.checkout.appendingPathComponent("Runner")) == (tree.checkout, .currentDirectory))
    // The link from make install resolves to the build product inside the checkout.
    #expect(try tree.resolve(executable: tree.link) == (tree.checkout, .executable))
    #expect(try tree.resolve(environment: [RunnerProject.environmentKey: ""], executable: tree.link).source == .executable)
  }

  @Test func theInstalledCopyComesLast() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let installed = RunnerProject.installedRoot(home: tree.home)
    try FileManager.default.createDirectory(at: installed.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
    // A relay binary copied away from its directory.
    let copied = tree.root.appendingPathComponent("elsewhere/bin/relay")

    // After an upgrade, an old relay install must not keep being built: the executable's directory wins.
    #expect(try tree.resolve(executable: tree.link) == (tree.checkout, .executable))
    // Nothing around the executable: the installed copy.
    #expect(try tree.resolve(executable: copied) == (installed, .installed))
    #expect(try tree.resolve() == (installed, .installed))
    // Inside the checkout (xcrun swift run relay start): its sources, not an older installed copy.
    #expect(try tree.resolve(current: tree.checkout, executable: copied) == (tree.checkout, .currentDirectory))
    #expect(try tree.resolve(current: tree.checkout.appendingPathComponent("Runner")) == (tree.checkout, .currentDirectory))
    #expect(try tree.resolve(environment: [RunnerProject.environmentKey: tree.checkout.path]) == (tree.checkout, .environment))
    // Inside the installed copy itself it is not a checkout.
    #expect(try tree.resolve(current: installed, executable: copied) == (installed, .installed))
    #expect(try tree.resolve(current: installed, executable: tree.link) == (tree.checkout, .executable))
    // relay install looks for a checkout only, even from inside the installed copy.
    #expect(try tree.resolve(current: installed, executable: tree.link, includeInstalled: false) == (tree.checkout, .executable))
    #expect(throws: SetupError.self) { try tree.resolve(current: installed, executable: copied, includeInstalled: false) }
  }

  /// The layout of a release tarball, as extracted by hand or by mise, with `bin/relay` linked from elsewhere.
  @Test func aLinkToAnExtractedReleaseFindsItsRunner() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let manager = FileManager.default
    let release = tree.root.appendingPathComponent("device-relay-v1.2.3")
    let binary = release.appendingPathComponent("bin/relay")
    try manager.createDirectory(at: release.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
    try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    manager.createFile(atPath: binary.path, contents: Data())
    let link = tree.root.appendingPathComponent("links/release-relay")
    try manager.createSymbolicLink(at: link, withDestinationURL: binary)
    // An older relay install does not get in the way.
    try manager.createDirectory(at: RunnerProject.installedRoot(home: tree.home).appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)

    #expect(try tree.resolve(executable: binary).source == .executable)
    let found = try tree.resolve(executable: link)
    #expect(found.source == .executable)
    #expect(found.root.canonicalFileURL.path == release.canonicalFileURL.path)
    #expect(try tree.resolve(executable: link, includeInstalled: false).source == .executable)
  }

  @Test func aMissingRunnerSaysWhatACopiedBinaryNeeds() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    let copied = tree.root.appendingPathComponent("elsewhere/bin/relay")

    let missing: String = #expect(throws: SetupError.self) { try tree.resolve(executable: copied) }?.description ?? ""
    #expect(missing.contains("copied away from its directory needs relay install run once from the extracted release directory (or the checkout)"))
    #expect(missing.contains("--project"))
    let toInstall: String = #expect(throws: SetupError.self) { try tree.resolve(executable: copied, includeInstalled: false) }?.description ?? ""
    #expect(toInstall.contains("run relay install from inside one"))
  }

  @Test func buildsGoUnderTheHomeDirectoryPerSource() {
    let home = URL(fileURLWithPath: "/Users/me")
    #expect(RunnerProject.buildDirectory(root: RunnerProject.installedRoot(home: home), home: home).path == "/Users/me/.relay/build/installed")
    let a = RunnerProject.buildDirectory(root: URL(fileURLWithPath: "/src/device-relay"), home: home)
    let b = RunnerProject.buildDirectory(root: URL(fileURLWithPath: "/work/device-relay"), home: home)
    #expect(a.path.hasPrefix("/Users/me/.relay/build/device-relay-"))
    #expect(a != b)
  }

  @Test func givenPathsMustHoldTheProject() throws {
    let tree = try Tree()
    defer { try? FileManager.default.removeItem(at: tree.root) }
    // No fallback to the checkout found from the executable.
    #expect(throws: SetupError.self) { try tree.resolve(tree.root.path, executable: tree.link) }
    #expect(throws: SetupError.self) { try tree.resolve(environment: [RunnerProject.environmentKey: tree.current.path], executable: tree.link) }
    #expect {
      try tree.resolve(executable: tree.root.appendingPathComponent("elsewhere/relay"))
    } throws: { error in
      String(describing: error).contains("--project") && String(describing: error).contains(RunnerProject.environmentKey)
    }
  }
}
