import Foundation
@testable import Relay
import Testing

struct SkillTests {
    /// <root>/home (with relay install's copy when `installed`), <root>/checkout (a git checkout: it has
    /// `.git`), and <root>/app, a git repository whose root the fake git reports for <root>/app/sub.
    private struct Tree {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var checkout: URL { root.appendingPathComponent("checkout") }
        var app: URL { root.appendingPathComponent("app") }
        var appSub: URL { app.appendingPathComponent("sub") }
        var installedSkill: URL { AgentSkill.installedSource(home: home) }
        var projectSkill: URL { app.appendingPathComponent(".claude/skills/device-relay") }
        var globalSkill: URL { home.appendingPathComponent(".claude/skills/device-relay") }

        init(installed: Bool = true, installedVersion: String = RelayVersion.current) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            for directory in [checkout.appendingPathComponent(RunnerProject.projectPath), checkout.appendingPathComponent(".git"), appSub] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try write("checkout skill", to: checkout.appendingPathComponent(AgentSkill.path + "/SKILL.md"))
            try write("checkout reference", to: checkout.appendingPathComponent(AgentSkill.path + "/reference.md"))
            if installed {
                let runner = RunnerProject.installedRoot(home: home)
                try FileManager.default.createDirectory(at: runner.appendingPathComponent(RunnerProject.projectPath), withIntermediateDirectories: true)
                try write("installed skill", to: installedSkill.appendingPathComponent("SKILL.md"))
                try RunnerInstallRecord(relayVersion: installedVersion, commit: String(repeating: "a", count: 40), source: checkout.path,
                                        installedAt: "1970-01-01T00:00:00Z").write(root: runner)
            }
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func text(_ url: URL, _ file: String = "SKILL.md") -> String? {
            try? String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
        }

        /// git: `rev-parse --show-toplevel` answers <root>/app for directories in it; `rev-parse HEAD` a commit.
        var commands: HostCommands {
            let app = app
            return HostCommands(
                xcrun: { args, _ in throw ShellError(args: args, status: 1, output: "") },
                devicectlJSON: { args, _ in throw ShellError(args: args, status: 1, output: "") },
                run: { executable, args, _ in
                    guard executable == "/usr/bin/git", args.count == 4 else { throw ShellError(args: args, status: 1, output: "") }
                    if args[3] == "HEAD" { return String(repeating: "c", count: 40) + "\n" }
                    guard args[1].hasPrefix(app.path) else { throw ShellError(args: args, status: 128, output: "not a git repository") }
                    return app.path + "\n"
                }
            )
        }

        @discardableResult
        func run(_ arguments: [String], currentDirectory: URL? = nil, checkout: Bool = true) throws -> (status: Int32, lines: [String]) {
            var lines: [String] = []
            let status = try SkillCommand.run(try Arguments.parseSkill(arguments), commands: commands, home: home,
                                              currentDirectory: currentDirectory ?? appSub, findCheckout: { checkout ? self.checkout : nil },
                                              now: Date(timeIntervalSince1970: 0), output: { lines.append($0) })
            return (status, lines)
        }
    }

    @Test func destinationsAreCanonicalButALinkStaysALink() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        // The current directory as the process sees it after cd into a /tmp or /var/folders path.
        let privateApp = URL(fileURLWithPath: "/private" + tree.app.path)
        let destination = SkillInstaller.destination(.project, home: tree.home, currentDirectory: privateApp, commands: tree.commands)
        #expect(destination.path == tree.projectSkill.path)
        #expect(SkillInstaller.destination(.directory("/private" + tree.app.path + "/skills"), home: tree.home, currentDirectory: tree.app,
                                           commands: tree.commands).path == tree.app.path + "/skills/device-relay")

        let (_, lines) = try tree.run(["install", "--link"], currentDirectory: privateApp)
        #expect(lines == ["installed the device-relay skill: \(tree.projectSkill.path) -> \(tree.checkout.path)/skills/device-relay (link, relay \(RelayVersion.current), commit cccccccccccc)"])
        #expect(SkillInstaller.destination(.project, home: tree.home, currentDirectory: privateApp, commands: tree.commands).path == tree.projectSkill.path)
        #expect(InstalledSkill.inspect(tree.projectSkill) == .link(tree.checkout.appendingPathComponent(AgentSkill.path).standardizedFileURL))
    }

    @Test func parsesSkillCommands() throws {
        #expect(try Arguments.parse(["skill", "install"]) == .skill(SkillOptions(action: .install)))
        #expect(try Arguments.parseSkill(["install", "--global", "--link", "--force"])
            == SkillOptions(action: .install, scope: .global, link: true, force: true))
        #expect(try Arguments.parseSkill(["uninstall", "--dir", "x/skills"]) == SkillOptions(action: .uninstall, scope: .directory("x/skills")))
        #expect(try Arguments.parseSkill(["status"]) == SkillOptions(action: .status))
        #expect(try Arguments.parseSkill(["--help"]) == SkillOptions(action: .help))
        #expect(try Arguments.parseSkill(["install", "--help"]) == SkillOptions(action: .help))
        #expect(throws: ArgumentError.self) { try Arguments.parseSkill([]) }
        #expect(throws: ArgumentError.self) { try Arguments.parseSkill(["install", "--global", "--dir", "x"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parseSkill(["install", "--dir"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parseSkill(["uninstall", "--force"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parseSkill(["status", "--link"]) }
        #expect(Arguments.helpCommand(for: "skill") == "relay skill --help")
    }

    @Test func installsIntoTheGitRootOrTheCurrentDirectory() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let outside = tree.root.appendingPathComponent("outside")
        #expect(SkillInstaller.destination(.project, home: tree.home, currentDirectory: tree.appSub, commands: tree.commands).path == tree.projectSkill.path)
        #expect(SkillInstaller.destination(.project, home: tree.home, currentDirectory: outside, commands: tree.commands).path
            == outside.appendingPathComponent(".claude/skills/device-relay").path)
        #expect(SkillInstaller.destination(.global, home: tree.home, currentDirectory: outside, commands: tree.commands).path == tree.globalSkill.path)
        #expect(SkillInstaller.destination(.directory("../agents"), home: tree.home, currentDirectory: tree.appSub, commands: tree.commands).path
            == tree.app.appendingPathComponent("agents/device-relay").path)
    }

    @Test func fallsBackToTheInstalledCopyAndRecordsTheVersion() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let (status, lines) = try tree.run(["install"], checkout: false)
        #expect(status == 0)
        #expect(lines == ["installed the device-relay skill in \(tree.projectSkill.path) (relay \(RelayVersion.current), commit aaaaaaaaaaaa, from \(tree.installedSkill.path))"])
        #expect(tree.text(tree.projectSkill) == "installed skill")
        #expect(SkillInstallRecord.read(directory: tree.projectSkill) == SkillInstallRecord(
            relayVersion: RelayVersion.current, commit: String(repeating: "a", count: 40), source: tree.installedSkill.path,
            installedAt: "1970-01-01T00:00:00Z"))
        // Nothing is left next to it, and the home directory is untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.projectSkill.deletingLastPathComponent().path) == ["device-relay"])
        #expect(!FileManager.default.fileExists(atPath: tree.globalSkill.deletingLastPathComponent().path))
    }

    @Test func comesFromTheCheckoutWithoutAnInstalledCopy() throws {
        let tree = try Tree(installed: false)
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.run(["install", "--global"])
        #expect(tree.text(tree.globalSkill) == "checkout skill")
        #expect(tree.text(tree.globalSkill, "reference.md") == "checkout reference")
        #expect(SkillInstallRecord.read(directory: tree.globalSkill)?.commit == String(repeating: "c", count: 40))

        #expect(throws: SetupError.self) { try tree.run(["install"], checkout: false) }
    }

    /// After an upgrade, an old relay install must not keep handing out its skill: the same order as the runner.
    @Test func theCheckoutWinsOverAnOutdatedInstalledCopy() throws {
        let tree = try Tree(installedVersion: "0.0.1")
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let (_, lines) = try tree.run(["install"])
        #expect(lines.first?.hasSuffix("from \(tree.checkout.appendingPathComponent(AgentSkill.path).path))") == true)
        #expect(tree.text(tree.projectSkill) == "checkout skill")
        #expect(SkillInstallRecord.read(directory: tree.projectSkill)?.relayVersion == RelayVersion.current)
        // Nothing to warn about: the outdated copy is not the source.
        let status = try tree.run(["status"]).lines
        #expect(status[0].hasPrefix("  ✓ source"))
        #expect(status[0].hasSuffix("from checkout)"))
        #expect(status[1].hasPrefix("  ✓ project"))

        // --link follows the same order, and falls back the same way.
        try tree.run(["install", "--global", "--link"])
        #expect(InstalledSkill.inspect(tree.globalSkill) == .link(tree.checkout.appendingPathComponent(AgentSkill.path).standardizedFileURL))
        let directory = tree.root.appendingPathComponent("links")
        try tree.run(["install", "--dir", directory.path, "--link"], checkout: false)
        #expect(InstalledSkill.inspect(directory.appendingPathComponent(AgentSkill.name)) == .link(tree.installedSkill.standardizedFileURL))
    }

    @Test func updatesItsOwnCopyButNotSomethingElse() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.run(["install"])
        try tree.write("leftover", to: tree.projectSkill.appendingPathComponent("old.md"))
        try tree.write("checkout skill v2", to: tree.checkout.appendingPathComponent(AgentSkill.path + "/SKILL.md"))
        #expect(try tree.run(["install"]).lines.first?.hasPrefix("updated the device-relay skill in \(tree.projectSkill.path)") == true)
        #expect(tree.text(tree.projectSkill) == "checkout skill v2")
        #expect(tree.text(tree.projectSkill, "old.md") == nil)

        // A skill of the same name that relay did not install.
        let other = tree.root.appendingPathComponent("other/device-relay")
        try tree.write("someone else's", to: other.appendingPathComponent("SKILL.md"))
        #expect(throws: SetupError.self) { try tree.run(["install", "--dir", "../../other"]) }
        #expect(tree.text(other) == "someone else's")
        #expect(throws: SetupError.self) { try tree.run(["uninstall", "--dir", "../../other"]) }
        #expect(tree.text(other) == "someone else's")
        #expect(try tree.run(["install", "--dir", "../../other", "--force"]).lines.first?.hasPrefix("replaced") == true)
        #expect(tree.text(other) == "checkout skill v2")
    }

    @Test func linksToTheCheckoutForDevelopment() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.run(["install", "--link"])
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: tree.projectSkill.path)
        #expect(target == tree.checkout.appendingPathComponent(AgentSkill.path).path)
        #expect(InstalledSkill.inspect(tree.projectSkill) == .link(URL(fileURLWithPath: target)))
        // A copy replaces the link; the checkout stays as it is.
        try tree.run(["install"])
        #expect(InstalledSkill.inspect(tree.projectSkill) != .link(URL(fileURLWithPath: target)))
        #expect(tree.text(tree.projectSkill) == "checkout skill")
        #expect(tree.text(tree.checkout.appendingPathComponent(AgentSkill.path)) == "checkout skill")
        // A link elsewhere is not relay's.
        try FileManager.default.removeItem(at: tree.projectSkill)
        try FileManager.default.createSymbolicLink(at: tree.projectSkill, withDestinationURL: tree.app)
        #expect(InstalledSkill.inspect(tree.projectSkill) == .foreign)
    }

    @Test func uninstallRemovesOnlyWhatRelayInstalled() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        #expect(try tree.run(["uninstall"]).lines == ["the device-relay skill is not installed in \(tree.projectSkill.path)"])
        try tree.run(["install", "--global", "--link"])
        #expect(try tree.run(["uninstall", "--global"]).lines == ["removed \(tree.globalSkill.path)"])
        #expect(!FileManager.default.fileExists(atPath: tree.globalSkill.path))
        #expect(tree.text(tree.checkout.appendingPathComponent(AgentSkill.path)) == "checkout skill")
        try tree.run(["install"])
        try tree.run(["uninstall"])
        #expect(!FileManager.default.fileExists(atPath: tree.projectSkill.path))
    }

    @Test func statusMarksOutdatedSkills() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var lines = try tree.run(["status"]).lines
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("  ✓ source"))
        #expect(lines[1].hasSuffix("\(tree.projectSkill.path): not installed"))
        #expect(lines[2].hasSuffix("\(tree.globalSkill.path): not installed"))

        try tree.run(["install"])
        var record = try #require(SkillInstallRecord.read(directory: tree.projectSkill))
        #expect(try tree.run(["status"]).lines[1].hasPrefix("  ✓ project"))
        record.relayVersion = "0.0.1"
        try record.write(directory: tree.projectSkill)
        lines = try tree.run(["status"]).lines
        #expect(lines[1].hasPrefix("  ! project"))
        #expect(lines[1].contains("written for relay 0.0.1"))
        #expect(lines[1].contains("→ run relay skill install to update it"))

        // A copy of an older commit than the source.
        record.relayVersion = RelayVersion.current
        record.commit = String(repeating: "b", count: 40)
        try record.write(directory: tree.projectSkill)
        lines = try tree.run(["status"]).lines
        #expect(lines[1].hasPrefix("  ! project"))
        #expect(lines[1].contains(", commit bbbbbbbbbbbb, 1970-01-01T00:00:00Z): differs from the source "
            + "\(tree.checkout.appendingPathComponent(AgentSkill.path).path) (relay \(RelayVersion.current), commit cccccccccccc)"))
        #expect(lines[1].hasSuffix("→ run relay skill install to update it"))
        #expect(try tree.run(["status", "--dir", "../.claude/skills"]).lines[1].hasPrefix("  ! directory"))

        try tree.write("x", to: tree.globalSkill.appendingPathComponent("SKILL.md"))
        #expect(try tree.run(["status", "--global"]).lines[1].contains("was not installed by relay"))
    }

    /// Where the source is from: a root with `.git` (a directory, or a file in a git worktree) is a checkout,
    /// one without is an extracted release, whatever git says; else relay install's copy.
    @Test func statusNamesWhereTheSourceIsFrom() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let git = tree.checkout.appendingPathComponent(".git")
        func sourceLine(checkout: Bool = true) throws -> String { try tree.run(["status"], checkout: checkout).lines[0] }
        #expect(try sourceLine().hasSuffix("(relay \(RelayVersion.current), from checkout)"))

        try FileManager.default.removeItem(at: git)
        #expect(try sourceLine().hasSuffix("(relay \(RelayVersion.current), from release)"))
        // git would answer with a commit for a release extracted inside another repository: that commit is the other
        // repository's, so the release has none, and is not a checkout.
        let release = try SkillSource.resolve(home: tree.home, commands: tree.commands) { tree.checkout }
        #expect(release.commit == nil)
        #expect(release.label == "release")

        try tree.write("gitdir: /elsewhere/.git/worktrees/checkout", to: git)
        #expect(try sourceLine().hasSuffix("from checkout)"))

        // A checkout where git is missing or fails is still a checkout.
        try FileManager.default.removeItem(at: git)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let noGit = HostCommands(xcrun: tree.commands.xcrun, devicectlJSON: tree.commands.devicectlJSON,
                                 run: { _, args, _ in throw ShellError(args: args, status: 127, output: "") })
        let source = try SkillSource.resolve(home: tree.home, commands: noGit) { tree.checkout }
        #expect(source.label == "checkout")
        #expect(source.commit == nil)

        #expect(try sourceLine(checkout: false).hasSuffix("\(tree.installedSkill.path) (relay \(RelayVersion.current), from relay install)"))
    }

    /// The source may be older than the installed copy: the message says they differ, not which is newer.
    @Test func statusSaysAnOlderSourceDiffers() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        // Installed from the checkout at commit ccc…; relay install's copy is from the older commit aaa….
        try tree.run(["install"])
        let line = try tree.run(["status"], checkout: false).lines[1]
        #expect(line.hasPrefix("  ! project"))
        #expect(line.contains("(relay \(RelayVersion.current), commit cccccccccccc, 1970-01-01T00:00:00Z): differs from the source "
            + "\(tree.installedSkill.path) (relay \(RelayVersion.current), commit aaaaaaaaaaaa)"))
        #expect(!line.contains("newer"))
        #expect(line.hasSuffix("→ run relay skill install to update it"))
    }

    /// A relay binary with no checkout to find: its source is the copy, however old.
    @Test func statusAsksForRelayInstallWhenItsCopyIsOutdatedAndTheOnlySource() throws {
        let tree = try Tree(installedVersion: "0.0.1")
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try tree.run(["install"], checkout: false)
        try tree.run(["install", "--global"], checkout: false)
        var lines = try tree.run(["status"], checkout: false).lines
        #expect(lines[1].hasPrefix("  ! project"))
        #expect(lines[1].contains("written for relay 0.0.1"))
        #expect(lines[1].contains("→ run relay install, then relay skill install"))
        #expect(try tree.run(["status", "--global"], checkout: false).lines[1].hasSuffix("→ run relay install, then relay skill install --global"))

        // Once a checkout can be found, relay install is not part of the fix.
        #expect(try tree.run(["status"]).lines[1].hasSuffix("→ run relay skill install to update it"))

        // Once relay install has refreshed its copy, only the installed skill is out of date.
        var runner = try #require(RunnerInstallRecord.read(root: RunnerProject.installedRoot(home: tree.home)))
        runner.relayVersion = RelayVersion.current
        try runner.write(root: RunnerProject.installedRoot(home: tree.home))
        lines = try tree.run(["status"], checkout: false).lines
        #expect(lines[1].hasPrefix("  ! project"))
        #expect(lines[1].hasSuffix("→ run relay skill install to update it"))
    }

    @Test func relayInstallCopiesTheSkillWithTheRunner() throws {
        let tree = try Tree(installed: false)
        defer { try? FileManager.default.removeItem(at: tree.root) }
        try "".write(to: tree.checkout.appendingPathComponent(RunnerProject.projectPath + "/project.pbxproj"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tree.checkout.appendingPathComponent("Runner/RelayRunnerUITests"), withIntermediateDirectories: true)
        var lines: [String] = []
        #expect(try InstallCommand.run(InstallOptions(project: tree.checkout.path), commands: tree.commands, home: tree.home,
                                       output: { lines.append($0) }) == 0)
        #expect(tree.text(tree.installedSkill) == "checkout skill")
        #expect(tree.text(tree.installedSkill, "reference.md") == "checkout reference")
        #expect(lines.last == "the device-relay agent skill is in \(tree.installedSkill.path); relay skill install adds it to a project")
        #expect(try tree.run(["install"], checkout: false).lines.first?.contains("from \(tree.installedSkill.path)") == true)
    }

    @Test func doctorShowsTheSkillsAndMarksOutdatedOnes() throws {
        let tree = try Tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        func checks() -> [Check] {
            SkillInstaller.doctorChecks(home: tree.home, currentDirectory: tree.appSub, commands: tree.commands) { tree.checkout }
        }
        // Not having the skill is fine.
        #expect(checks().map(\.status) == [.ok])
        #expect(checks()[0].title == "agent skill")

        try tree.run(["install"])
        #expect(checks().map(\.title) == ["skill (project)"])
        #expect(checks()[0].status == .ok)
        var record = try #require(SkillInstallRecord.read(directory: tree.projectSkill))
        record.relayVersion = "0.0.1"
        try record.write(directory: tree.projectSkill)
        try tree.write("x", to: tree.globalSkill.appendingPathComponent("SKILL.md"))
        let outdated = checks()
        #expect(outdated.map(\.title) == ["skill (project)", "skill (global)"])
        #expect(outdated.map(\.status) == [.warning, .warning])
        #expect(outdated[0].fix == "run relay skill install to update it")
        #expect(outdated[1].detail.hasSuffix("was not installed by relay"))
    }

    @Test func doctorListsTheSkill() {
        var lines: [String] = []
        _ = Doctor.run(DoctorOptions(), commands: HostCommands(xcrun: { _, _ in "" }, devicectlJSON: { _, _ in Data() }, run: { _, _, _ in "" }),
                       configURL: URL(fileURLWithPath: "/nonexistent/config.json"),
                       resolveProject: { _ in (URL(fileURLWithPath: "/relay"), .environment) }, home: URL(fileURLWithPath: "/nonexistent"),
                       output: { lines.append($0) })
        #expect(lines.contains { $0.hasPrefix("  ✓ agent skill") || $0.contains("skill (project)") || $0.contains("skill (global)") })
    }

}
