import CryptoKit
import Foundation

/// A digest of the sources the runner is built from: every file under `Runner/` and the CLI sources the
/// project compiles (`CheckoutRunnerSource.referencedFiles`). It decides whether a previous build can be
/// reused (`RunnerBuildPlan`), and is built into the runner, which reports it from `/ping` and `/health`.
///
/// The installed copy holds the same files as the checkout it was copied from, so both hash the same.
/// Per-user Xcode state (`xcuserdata`, which `relay install` drops) and hidden files (`.DS_Store`) do not
/// change the build and are left out.
enum RunnerSourceHash {
    /// The paths, relative to `root`, that the hash covers, sorted.
    static func files(root: URL) throws -> [String] {
        let manager = FileManager.default
        let runner = root.appendingPathComponent("Runner", isDirectory: true)
        var paths: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = manager.enumerator(at: runner, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw ArgumentError(description: "cannot read \(runner.path)")
        }
        let prefix = runner.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if url.lastPathComponent == "xcuserdata" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            paths.append("Runner/" + path.dropFirst(prefix.count))
        }
        let pbxproj = root.appendingPathComponent(RunnerProject.projectPath).appendingPathComponent("project.pbxproj")
        paths += CheckoutRunnerSource.referencedFiles(pbxproj: try String(contentsOf: pbxproj, encoding: .utf8))
        return Array(Set(paths)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// The hash of the runner sources at `root`. Throws when a file cannot be read: the build would fail too.
    static func compute(root: URL) throws -> String {
        let files = try files(root: root)
        return try digest(files.map { path in (path, try Data(contentsOf: root.appendingPathComponent(path))) })
    }

    /// SHA-256 (hex) over each file's path and contents, in path order, so the order the files are listed
    /// in does not matter. Each path and contents is preceded by its length, so moving bytes between a
    /// file's name and its contents (or between two files) changes the hash.
    static func digest(_ files: [(path: String, contents: Data)]) -> String {
        var hasher = SHA256()
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            hasher.update(data: Data(bytes: &length, count: 8))
            hasher.update(data: data)
        }
        hasher.update(data: Data("relay-runner-sources-v1\n".utf8))
        for file in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            append(Data(file.path.utf8))
            append(file.contents)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first 12 digits, as relay shows the hash.
    static func short(_ hash: String) -> String {
        String(hash.prefix(12))
    }
}

/// What the runner says it was built from: `"runner": {"version": ..., "sourceHash": ...}` in `/ping` and
/// `/health`, and what `relay start` saves in runner.json. The runner reads both from its Info.plist,
/// where the build put them (`buildSettings`), so they describe the build, not the launch.
struct RunnerBuildVersion: Codable, Equatable {
    /// `RelayVersion.current` of the relay that built it.
    var version: String?
    var sourceHash: String?

    /// The build settings `relay start` and `relay install --build` pass to xcodebuild. The UI test
    /// target's Info.plist (`Runner/RelayRunnerUITests/Info.plist`) expands them into these keys.
    static let versionSetting = "RELAY_RUNNER_VERSION"
    static let sourceHashSetting = "RELAY_RUNNER_SOURCE_HASH"

    static func buildSettings(sourceHash: String, version: String = RelayVersion.current) -> [String] {
        ["\(versionSetting)=\(version)", "\(sourceHashSetting)=\(sourceHash)"]
    }

    /// The `runner` object of a `/ping` or `/health` body; nil when the runner does not report one (built
    /// before runners did). Empty values (a build without the settings, e.g. from Xcode) are nil.
    static func parse(responseBody data: Data) -> RunnerBuildVersion? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runner = object["runner"] as? [String: Any] else { return nil }
        func value(_ key: String) -> String? {
            (runner[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return RunnerBuildVersion(version: value("version"), sourceHash: value("sourceHash"))
    }

    /// `0.2.0 (sources 0123456789ab)`.
    var summary: String {
        let hash = sourceHash.map { "sources \(RunnerSourceHash.short($0))" } ?? "sources unknown"
        return "\(version ?? "unknown version") (\(hash))"
    }

    /// Why a runner that reports `reported` is not the build of `expected` sources, or nil when it is.
    static func mismatch(reported: RunnerBuildVersion?, expectedSourceHash: String) -> String? {
        guard let reported, let hash = reported.sourceHash else {
            return "the runner does not report its build (its sources predate that, or it was built without relay)"
        }
        guard hash == expectedSourceHash else {
            return "the runner reports sources \(RunnerSourceHash.short(hash)), but relay built \(RunnerSourceHash.short(expectedSourceHash))"
        }
        return nil
    }
}

/// Written next to the `.xctestrun` (`Build/Products`) after a build succeeds: which sources and which
/// relay the products were built from. A build without one (made by an older relay, or one that failed)
/// is never reused.
struct RunnerBuildStamp: Codable, Equatable {
    static let fileName = "relay-runner-build.json"

    var sourceHash: String
    var relayVersion: String
    /// The `RunnerBundleID` prefix it was built with. Nil in a stamp from a relay before prefixes, which is
    /// rebuilt: its bundle IDs are not known.
    var bundleIDPrefix: String?

    static func url(derivedData: URL) -> URL {
        derivedData.appendingPathComponent("Build/Products", isDirectory: true).appendingPathComponent(fileName)
    }

    static func read(derivedData: URL) -> RunnerBuildStamp? {
        try? JSONDecoder().decode(RunnerBuildStamp.self, from: Data(contentsOf: url(derivedData: derivedData)))
    }

    func write(derivedData: URL) throws {
        let url = Self.url(derivedData: derivedData)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Removed before a build: products a failed build may have half rewritten are not the stamp's anymore.
    static func remove(derivedData: URL) {
        try? FileManager.default.removeItem(at: url(derivedData: derivedData))
    }
}

/// Whether `relay start` reuses the last build or builds the runner.
enum RunnerBuildPlan: Equatable {
    case reuse(URL)
    /// `reason` is printed before building; nil for a first build or `--rebuild`.
    case build(reason: String?)

    /// The SDK check (`XCTestRunSelection`) comes first; a build for this SDK is then reused only while its
    /// stamp names the bundle ID prefix, the current sources, and this relay. The prefix is checked before the
    /// sources: its reason says the device gets new apps, which matters more than why the build is redone.
    static func decide(rebuild: Bool, selection: XCTestRunSelection.Reuse, platform: String, sdkVersion: String?,
                       stamp: RunnerBuildStamp?, sourceHash: String, bundleIDPrefix: String,
                       relayVersion: String = RelayVersion.current) -> RunnerBuildPlan {
        if rebuild { return .build(reason: nil) }
        switch selection {
        case .none:
            return .build(reason: nil)
        case .otherSDK(let file):
            return .build(reason: "\(file.lastPathComponent) (the last build) is not for this Xcode's \(platform) SDK \(sdkVersion ?? "?"); rebuilding")
        case .reuse(let url):
            guard let stamp else {
                return .build(reason: "the last build has no record of its runner sources (built by an older relay); rebuilding")
            }
            guard let builtPrefix = stamp.bundleIDPrefix else {
                return .build(reason: "the last build has no record of its bundle ID prefix (built by an older relay); rebuilding")
            }
            if builtPrefix != bundleIDPrefix {
                return .build(reason: RunnerBundleID.rebuildNote(from: builtPrefix, to: bundleIDPrefix))
            }
            if stamp.sourceHash != sourceHash {
                return .build(reason: "runner sources changed since the last build (\(RunnerSourceHash.short(stamp.sourceHash)) -> "
                    + "\(RunnerSourceHash.short(sourceHash))); rebuilding")
            }
            if stamp.relayVersion != relayVersion {
                return .build(reason: "the last build was made by relay \(stamp.relayVersion), this is relay \(relayVersion); rebuilding")
            }
            return .reuse(url)
        }
    }
}
