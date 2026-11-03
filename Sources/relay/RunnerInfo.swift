import Foundation

/// The running runner's URL and token, saved by `relay start` as `.relay/runner.json` for other clients.
struct RunnerInfo: Codable, Equatable {
    static let fileName = "runner.json"

    var url: String
    var token: String
    var udid: String
    /// The device's name, for `relay status`.
    var name: String?
    /// The `relay start` process that owns the runner, which `relay stop` sends SIGTERM to.
    var pid: Int32?
    /// When that process started (whole seconds). With `pid`, it tells the process apart from an
    /// unrelated one that reuses the pid later (see `RelayProcess`).
    var startedAt: Date?
    /// What the runner should report as its build (`/ping`'s `runner`): this relay's version and the
    /// sources relay built or reused. Saved so `relay status` compares without hashing the sources.
    var runner: RunnerBuildVersion?
    /// The bundle ID of the runner's host app (see `RunnerBundleID`), which the runner commands take as `host`.
    var hostBundleID: String?

    static func defaultURL(rootURL: URL = WorkingDirectory.url) -> URL {
        rootURL.appendingPathComponent(".relay", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Writes the file readable by the owner only. It is created with mode 0600 instead of being
    /// chmod-ed afterwards, so the token is never readable by others even briefly.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Drop a previous file, which may have looser permissions, so O_EXCL creates a fresh one.
        // unlink(2) never removes a directory, unlike FileManager.removeItem.
        Self.remove(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw ArgumentError(description: "cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func read(from url: URL) throws -> RunnerInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunnerInfo.self, from: Data(contentsOf: url))
    }

    static func remove(at url: URL) {
        unlink(url.path)
    }

    /// Removes the file only while it still holds `token`, so a runner that stops does not delete the
    /// shared copy another `relay start` has replaced since.
    static func remove(at url: URL, ifTokenIs token: String) {
        guard let info = try? read(from: url), info.token == token else { return }
        remove(at: url)
    }
}
