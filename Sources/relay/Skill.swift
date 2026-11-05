import Foundation

/// The agent skill in `skills/device-relay` of the checkout: instructions for coding agents (Claude Code and
/// the like) on driving apps with relay. `relay install` copies it next to the runner, and `relay skill
/// install` puts it where an agent looks for skills (`.claude/skills/device-relay`).
enum AgentSkill {
    static let name = "device-relay"
    /// Relative to a checkout, and to `relay install`'s copy, which keeps the checkout's layout.
    static let path = "skills/device-relay"

    static func installedSource(home: URL = UserHome.url) -> URL {
        RunnerProject.installedRoot(home: home).appendingPathComponent(path, isDirectory: true)
    }

    static func contains(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path)
    }

    /// Whether a symbolic link to `target` is one `relay skill install --link` made: it points at
    /// `skills/device-relay` of a checkout or of the installed copy, or at such a path that no longer exists.
    static func isRelaySkill(linkTarget target: URL) -> Bool {
        let target = target.standardizedFileURL
        guard target.path.hasSuffix("/" + path) else { return false }
        let root = target.deletingLastPathComponent().deletingLastPathComponent()
        return RunnerProject.contains(root) || !FileManager.default.fileExists(atPath: target.path)
    }
}

/// What `relay skill install` records next to SKILL.md of a copy, so the skill itself stays as written.
struct SkillInstallRecord: Codable, Equatable {
    static let fileName = ".relay-skill.json"

    var skill = AgentSkill.name
    /// The relay version the skill was written for (the version of the runner copy it came from).
    var relayVersion: String
    var commit: String?
    /// The directory the skill was copied from.
    var source: String
    var installedAt: String

    static func read(directory: URL) -> SkillInstallRecord? {
        try? JSONDecoder().decode(SkillInstallRecord.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    func write(directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Where the skill to install comes from.
struct SkillSource: Equatable {
    var directory: URL
    var relayVersion: String
    var commit: String?
    /// "relay install" or "checkout", for messages.
    var label: String

    /// `relay install`'s copy first, so a project gets the skill matching the installed runner; then the
    /// checkout `relay install` would copy from. `--link` prefers the checkout, so edits to it show at once.
    static func resolve(link: Bool, home: URL, commands: HostCommands, findCheckout: () -> URL?) throws -> SkillSource {
        func installed() -> SkillSource? {
            let directory = AgentSkill.installedSource(home: home)
            guard AgentSkill.contains(directory) else { return nil }
            let record = RunnerInstallRecord.read(root: RunnerProject.installedRoot(home: home))
            return SkillSource(directory: directory, relayVersion: record?.relayVersion ?? "unknown", commit: record?.commit,
                               label: "relay install")
        }
        func checkout() -> SkillSource? {
            guard let root = findCheckout() else { return nil }
            let directory = root.appendingPathComponent(AgentSkill.path, isDirectory: true)
            guard AgentSkill.contains(directory) else { return nil }
            return SkillSource(directory: directory, relayVersion: RelayVersion.current,
                               commit: CheckoutRunnerSource.commit(of: root, commands: commands), label: "checkout")
        }
        guard let source = link ? (checkout() ?? installed()) : (installed() ?? checkout()) else {
            throw SetupError(description: "cannot find the \(AgentSkill.name) skill (\(AgentSkill.path)); run relay install from a "
                + "device-relay checkout, or set \(RunnerProject.environmentKey)=<path to device-relay>")
        }
        return source
    }
}

struct SkillOptions: Equatable {
    enum Action: Equatable {
        case install
        case uninstall
        case status
        case help
    }

    enum Scope: Equatable {
        /// `.claude/skills` in the git root of the current directory, else in the current directory.
        case project
        /// `--global`: `~/.claude/skills`.
        case global
        /// `--dir <skills dir>`.
        case directory(String)
    }

    var action: Action
    /// Nil is `.project` for install and uninstall; status then shows the project and the global skill.
    var scope: Scope?
    var link = false
    var force = false
}

/// What is at a skill's destination.
enum InstalledSkill: Equatable {
    case none
    /// A copy with a record.
    case copy(SkillInstallRecord)
    /// A symbolic link to a relay skill (`--link`).
    case link(URL)
    /// Something relay did not install, or cannot tell.
    case foreign

    var isRelays: Bool {
        switch self {
        case .copy, .link: return true
        case .none, .foreign: return false
        }
    }

    static func inspect(_ destination: URL) -> InstalledSkill {
        let manager = FileManager.default
        if let target = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
            let url = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
            return AgentSkill.isRelaySkill(linkTarget: url) ? .link(url) : .foreign
        }
        guard manager.fileExists(atPath: destination.path) else { return .none }
        if let record = SkillInstallRecord.read(directory: destination), record.skill == AgentSkill.name {
            return .copy(record)
        }
        return .foreign
    }
}

enum SkillInstaller {
    /// `<skills dir>/device-relay` for a scope.
    static func destination(_ scope: SkillOptions.Scope, home: URL, currentDirectory: URL, commands: HostCommands) -> URL {
        let skills: URL
        switch scope {
        case .project:
            skills = projectRoot(currentDirectory: currentDirectory, commands: commands).appendingPathComponent(".claude/skills", isDirectory: true)
        case .global:
            skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .directory(let path):
            skills = RunnerLocator.resolve(path, in: currentDirectory)
        }
        // Only the directory is made canonical: the skill itself may be a link, which must stay the link.
        return skills.canonicalFileURL.appendingPathComponent(AgentSkill.name, isDirectory: true)
    }

    /// The git root of `currentDirectory`, else `currentDirectory`.
    static func projectRoot(currentDirectory: URL, commands: HostCommands) -> URL {
        if let output = try? commands.run("/usr/bin/git", ["-C", currentDirectory.path, "rev-parse", "--show-toplevel"]) {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true).canonicalFileURL
            }
        }
        return currentDirectory
    }

    /// Copies (or links) the skill to `destination`, replacing a skill relay installed there before. Anything
    /// else there is replaced only with `force`. A copy is staged next to the destination and swapped in, so
    /// a failure leaves the previous skill intact. Returns what was there before.
    @discardableResult
    static func install(_ source: SkillSource, to destination: URL, link: Bool, force: Bool, now: Date = Date()) throws -> InstalledSkill {
        let manager = FileManager.default
        let sourcePath = source.directory.canonicalFileURL.path
        guard destination.path != sourcePath, !destination.path.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(destination.path + "/") else {
            throw SetupError(description: "cannot install the skill from \(sourcePath) into itself (\(destination.path))")
        }
        let existing = InstalledSkill.inspect(destination)
        if existing == .foreign, !force {
            throw SetupError(description: "\(destination.path) exists and was not installed by relay; "
                + "pass --force to replace it, or --dir <skills dir> to install elsewhere")
        }
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".\(AgentSkill.name).new-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        if link {
            try manager.createSymbolicLink(at: staging, withDestinationURL: source.directory.canonicalFileURL)
        } else {
            try manager.copyItem(at: source.directory, to: staging)
            let record = SkillInstallRecord(relayVersion: source.relayVersion, commit: source.commit, source: sourcePath,
                                            installedAt: ISO8601DateFormatter().string(from: now))
            try record.write(directory: staging)
        }

        if existing == .none {
            try manager.moveItem(at: staging, to: destination)
        } else {
            let old = parent.appendingPathComponent(".\(AgentSkill.name).old-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: destination, to: old)
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch {
                try? manager.moveItem(at: old, to: destination)
                throw error
            }
            try? manager.removeItem(at: old)
        }
        return existing
    }

    /// Removes the skill at `destination` if relay installed it (a link is removed, not what it points to).
    /// Returns false when nothing is there.
    @discardableResult
    static func remove(_ destination: URL) throws -> Bool {
        switch InstalledSkill.inspect(destination) {
        case .none:
            return false
        case .foreign:
            throw SetupError(description: "\(destination.path) was not installed by relay; left as is")
        case .copy, .link:
            try FileManager.default.removeItem(at: destination)
            return true
        }
    }

    /// The state of the skill at `destination`, ✓ or ! (nil when nothing is there). `source` is what
    /// `relay skill install` would copy now, when found.
    static func check(_ title: String, scope: SkillOptions.Scope, destination: URL, source: SkillSource?, home: URL) -> Check? {
        let scopeOption: String
        switch scope {
        case .project: scopeOption = ""
        case .global: scopeOption = " --global"
        case .directory: scopeOption = " --dir <skills dir>"
        }
        let updateFix = "run relay skill install\(scopeOption) to update it"
        switch InstalledSkill.inspect(destination) {
        case .none:
            return nil
        case .foreign:
            return .warning(title, "\(destination.path) was not installed by relay",
                            fix: "relay skill install --force replaces it; relay skill uninstall leaves it alone")
        case .link(let target):
            guard AgentSkill.contains(target) else {
                return .warning(title, "\(destination.path) -> \(target.path), which no longer exists", fix: "run relay skill install --link\(scopeOption) again")
            }
            if target.canonicalFileURL.path == AgentSkill.installedSource(home: home).canonicalFileURL.path,
               let version = RunnerInstallRecord.read(root: RunnerProject.installedRoot(home: home))?.relayVersion, version != RelayVersion.current {
                return .warning(title, "\(destination.path) -> \(target.path), installed by relay \(version), but this is relay \(RelayVersion.current)",
                                fix: "run relay install again")
            }
            return .ok(title, "\(destination.path) -> \(target.path) (link)")
        case .copy(let record):
            // relay install's copy is itself from another relay, so installing from it again would not help.
            let staleSource = source.map {
                $0.directory.canonicalFileURL.path == AgentSkill.installedSource(home: home).canonicalFileURL.path
                    && $0.relayVersion != RelayVersion.current
            } ?? false
            let fix = staleSource ? "run relay install, then relay skill install\(scopeOption)" : updateFix
            let detail = "\(destination.path) (relay \(record.relayVersion)\(record.commit.map { ", commit \($0.prefix(12))" } ?? ""), \(record.installedAt))"
            if record.relayVersion != RelayVersion.current {
                return .warning(title, "\(detail): written for relay \(record.relayVersion), but this is relay \(RelayVersion.current)", fix: fix)
            }
            if let source, source.relayVersion != record.relayVersion || (source.commit != nil && record.commit != nil && source.commit != record.commit) {
                return .warning(title, "\(detail): \(source.directory.path) is newer (relay \(source.relayVersion)"
                    + "\(source.commit.map { ", commit \($0.prefix(12))" } ?? ""))", fix: fix)
            }
            return .ok(title, detail)
        }
    }
}

extension SkillInstaller {
    /// What `relay doctor` shows about the skill: the project's and the global one, ! when out of date or
    /// not relay's. Not having the skill is fine (relay works without it), so that is ✓ with a hint.
    static func doctorChecks(home: URL, currentDirectory: URL, commands: HostCommands, findCheckout: () -> URL?) -> [Check] {
        let source = try? SkillSource.resolve(link: false, home: home, commands: commands, findCheckout: findCheckout)
        let scopes: [(String, SkillOptions.Scope)] = [("skill (project)", .project), ("skill (global)", .global)]
        let checks = scopes.compactMap { title, scope in
            check(title, scope: scope,
                  destination: destination(scope, home: home, currentDirectory: currentDirectory, commands: commands),
                  source: source, home: home)
        }
        guard checks.isEmpty else { return checks }
        return [.ok("agent skill", "not installed in this project or ~/.claude/skills; relay skill install adds it")]
    }
}

enum SkillCommand {
    static let usage = """
    Usage:
      relay skill install [--global | --dir <skills dir>] [--link] [--force] relay skill uninstall
      [--global | --dir <skills dir>] relay skill status [--global | --dir <skills dir>]

    Installs the device-relay agent skill, which tells coding agents such as Claude Code how to check an
    app on a simulator or device with relay. By default it is copied to .claude/skills/device-relay in
    the git root of the current directory (the current directory outside git), where the team can commit
    it.
    --global installs it to ~/.claude/skills/device-relay, --dir to <skills dir>/device-relay.
    --link makes a symbolic link instead of a copy, for working on the skill in a checkout.
    The skill comes from the copy relay install made in ~/.relay/runner/skills (with --link, a checkout
    first), else from the device-relay checkout relay install copies from. A copy records the relay
    version in .relay-skill.json next to SKILL.md. A skill relay installed is updated in place; anything
    else at the destination is replaced only with --force. uninstall removes only a skill relay
    installed.
    status shows where the skill is installed, marking with ! one that is out of date.
    """

    static func run(
        _ options: SkillOptions,
        commands: HostCommands = .live,
        home: URL = UserHome.url,
        currentDirectory: URL = WorkingDirectory.url,
        findCheckout: (() -> URL?)? = nil,
        now: Date = Date(),
        output: (String) -> Void = { print($0) }
    ) throws -> Int32 {
        let findCheckout = findCheckout ?? {
            try? RunnerProject.resolve(explicitPath: nil, currentDirectory: currentDirectory, home: home, includeInstalled: false).root
        }
        func destination(_ scope: SkillOptions.Scope) -> URL {
            SkillInstaller.destination(scope, home: home, currentDirectory: currentDirectory, commands: commands)
        }

        switch options.action {
        case .help:
            output(usage)
        case .install:
            let source = try SkillSource.resolve(link: options.link, home: home, commands: commands, findCheckout: findCheckout)
            let target = destination(options.scope ?? .project)
            let previous = try SkillInstaller.install(source, to: target, link: options.link, force: options.force, now: now)
            let verb = previous == .none ? "installed" : previous == .foreign ? "replaced" : "updated"
            let version = "relay \(source.relayVersion)\(source.commit.map { ", commit \($0.prefix(12))" } ?? "")"
            output(options.link
                ? "\(verb) the \(AgentSkill.name) skill: \(target.path) -> \(source.directory.path) (link, \(version))"
                : "\(verb) the \(AgentSkill.name) skill in \(target.path) (\(version), from \(source.directory.path))")
        case .uninstall:
            let target = destination(options.scope ?? .project)
            output(try SkillInstaller.remove(target) ? "removed \(target.path)" : "the \(AgentSkill.name) skill is not installed in \(target.path)")
        case .status:
            let source = try? SkillSource.resolve(link: false, home: home, commands: commands, findCheckout: findCheckout)
            output((source.map { Check.ok("source", "\($0.directory.path) (relay \($0.relayVersion), from \($0.label))") }
                ?? .warning("source", "\(AgentSkill.path) not found", fix: "run relay install from a device-relay checkout")).formatted())
            let scopes: [(String, SkillOptions.Scope)]
            switch options.scope {
            case nil: scopes = [("project", .project), ("global", .global)]
            case .project?: scopes = [("project", .project)]
            case .global?: scopes = [("global", .global)]
            case .directory(let path)?: scopes = [("directory", .directory(path))]
            }
            for (title, scope) in scopes {
                let target = destination(scope)
                output(SkillInstaller.check(title, scope: scope, destination: target, source: source, home: home)?.formatted()
                    ?? "  - \(title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(target.path): not installed")
            }
        }
        return RunnerExitCode.success.rawValue
    }
}

extension Arguments {
    /// `relay skill <install|uninstall|status> [--global | --dir <skills dir>] [--link] [--force]`.
    static func parseSkill(_ raw: [String]) throws -> SkillOptions {
        var rest = raw
        let action: SkillOptions.Action
        switch rest.first {
        case "install": action = .install
        case "uninstall": action = .uninstall
        case "status": action = .status
        case "-h", "--help", "help": return SkillOptions(action: .help)
        default: throw ArgumentError(description: "skill takes install, uninstall, or status")
        }
        rest.removeFirst()
        var options = SkillOptions(action: action)
        func setScope(_ scope: SkillOptions.Scope) throws {
            guard options.scope == nil else {
                throw ArgumentError(description: "skill takes either --global or --dir, not both")
            }
            options.scope = scope
        }
        while !rest.isEmpty {
            let option = rest.removeFirst()
            switch option {
            case "-h", "--help": return SkillOptions(action: .help)
            case "--global": try setScope(.global)
            case "--dir":
                guard !rest.isEmpty, !rest[0].hasPrefix("--") else {
                    throw ArgumentError(description: "--dir requires a value")
                }
                try setScope(.directory(rest.removeFirst()))
            case "--link" where action == .install: options.link = true
            case "--force" where action == .install: options.force = true
            default: throw ArgumentError(description: "unknown option: \(option)")
            }
        }
        return options
    }
}
