import Foundation
import Security

/// Settings relay remembers between runs, in `~/.relay/config.json`. Only the signing team for now.
struct RelayConfig: Codable, Equatable {
    static let keys = ["teamID"]

    var teamID: String?

    static func defaultURL(home: URL = UserHome.url) -> URL {
        home.appendingPathComponent(".relay", isDirectory: true).appendingPathComponent("config.json")
    }

    /// An empty config when the file does not exist yet.
    static func read(from url: URL = defaultURL()) throws -> RelayConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return RelayConfig() }
        do {
            return try JSONDecoder().decode(RelayConfig.self, from: Data(contentsOf: url))
        } catch {
            throw SetupError(description: "cannot read \(url.path): \(error)")
        }
    }

    func write(to url: URL = defaultURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Apple Team IDs are 10 characters of uppercase letters and digits.
    static func isValidTeamID(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}

/// A development code signing identity in the keychain and the team its certificate belongs to.
struct SigningIdentity: Equatable {
    var sha1: String
    /// `Apple Development: Name (XXXXXXXXXX)`. The ID in parentheses is the person's, not the team's.
    var name: String
    /// The certificate subject's organizational unit, which is the Team ID. Nil if it could not be read.
    var teamID: String?
}

/// Finds the Team ID to sign the runner with for a device.
///
/// Order: `--team-id`, then `teamID` in `~/.relay/config.json`, then the Apple Development certificates
/// in the keychain when they all belong to one team.
enum TeamIDResolver {
    enum Source: String {
        case option = "--team-id"
        case config = "~/.relay/config.json"
        case keychain = "keychain"
    }

    static func resolve(explicit: String?, config: RelayConfig, identities: () throws -> [SigningIdentity]) throws -> (teamID: String, source: Source) {
        if let explicit {
            return (explicit, .option)
        }
        if let teamID = config.teamID {
            return (teamID, .config)
        }
        let found = try identities()
        let teams = teamIDs(in: found)
        switch teams.count {
        case 1:
            return (teams[0], .keychain)
        case 0:
            let unread = found.isEmpty ? "" : " (\(found.count) found, but their team could not be read)"
            throw SetupError(description: "no Apple Development certificate in the keychain\(unread); sign in to your Apple Account "
                + "in Xcode > Settings > Accounts and create one under Manage Certificates, or pass --team-id <TEAM_ID>")
        default:
            let lines = teams.map { team in
                "  \(team)  " + found.filter { $0.teamID == team }.map(\.name).joined(separator: ", ")
            }
            throw SetupError(description: "the keychain has development certificates of \(teams.count) teams; pass --team-id "
                + "<TEAM_ID> once (it is saved), or relay config set teamID <TEAM_ID>:\n" + lines.joined(separator: "\n"))
        }
    }

    /// Distinct Team IDs, in keychain order.
    static func teamIDs(in identities: [SigningIdentity]) -> [String] {
        var seen = Set<String>()
        return identities.compactMap(\.teamID).filter { seen.insert($0).inserted }
    }
}

/// Reads the development signing identities from the keychain with `security`.
enum SigningIdentities {
    static let developmentPrefixes = ["Apple Development:", "iPhone Developer:"]

    static func load(_ commands: HostCommands = .live) throws -> [SigningIdentity] {
        let identities = parseFindIdentity(try commands.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]))
            .filter { identity in developmentPrefixes.contains { identity.name.hasPrefix($0) } }
        guard !identities.isEmpty else { return [] }
        var certificates: [String: Data] = [:]
        for prefix in developmentPrefixes {
            // Nonzero when no certificate matches the name.
            if let output = try? commands.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "-p", "-c", prefix]) {
                certificates.merge(parseFindCertificate(output)) { first, _ in first }
            }
        }
        return identities.map { identity in
            var identity = identity
            identity.teamID = certificates[identity.sha1].flatMap { organizationalUnits(certificate: $0).first }
            return identity
        }
    }

    /// Parses `security find-identity -v -p codesigning`, whose lines look like
    /// `  1) 0123...ABCD "Apple Development: Name (XXXXXXXXXX)"`.
    static func parseFindIdentity(_ output: String) -> [SigningIdentity] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[0].hasSuffix(")"), fields[1].count == 40,
                  fields[2].hasPrefix("\""), let close = fields[2].lastIndex(of: "\""), close > fields[2].startIndex else {
                return nil
            }
            let name = fields[2][fields[2].index(after: fields[2].startIndex)..<close]
            return SigningIdentity(sha1: fields[1].uppercased(), name: String(name))
        }
    }

    /// Parses `security find-certificate -a -Z -p`: a `SHA-1 hash: <hex>` line before each PEM block.
    /// Returns the DER of each certificate by its SHA-1.
    static func parseFindCertificate(_ output: String) -> [String: Data] {
        var certificates: [String: Data] = [:]
        var sha1: String?
        var base64: String?
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("SHA-1 hash:") {
                sha1 = line.dropFirst("SHA-1 hash:".count).trimmingCharacters(in: .whitespaces).uppercased()
            } else if line == "-----BEGIN CERTIFICATE-----" {
                base64 = ""
            } else if line == "-----END CERTIFICATE-----" {
                if let sha1, let base64, let der = Data(base64Encoded: base64) {
                    certificates[sha1] = der
                }
                sha1 = nil
                base64 = nil
            } else if base64 != nil {
                base64? += line
            }
        }
        return certificates
    }

    /// The subject's organizational units (OU). For Apple Development certificates it is the Team ID.
    static func organizationalUnits(certificate der: Data) -> [String] {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return []
        }
        return fields.compactMap { field in
            field[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String
                ? field[kSecPropertyKeyValue as String] as? String
                : nil
        }
    }
}

/// `relay config`: shows or changes `~/.relay/config.json`.
enum ConfigCommand {
    static func run(_ options: ConfigOptions, url: URL = RelayConfig.defaultURL(), output: (String) -> Void = { print($0) }) -> Int32 {
        do {
            var config = try RelayConfig.read(from: url)
            switch options.action {
            case .show:
                output("# \(url.path)")
                output("teamID: \(config.teamID ?? "(not set)")")
            case .get:
                // teamID is the only key. Nothing on stdout when unset, so scripts can test the exit code.
                guard let teamID = config.teamID else {
                    FileHandle.standardError.write(Data("relay: teamID is not set\n".utf8))
                    return RunnerExitCode.usage.rawValue
                }
                output(teamID)
            case .set(_, let value):
                config.teamID = value
                try config.write(to: url)
            case .unset:
                config.teamID = nil
                try config.write(to: url)
            }
            return RunnerExitCode.success.rawValue
        } catch {
            FileHandle.standardError.write(Data("relay: \(error)\n".utf8))
            return RunnerExitCode.usage.rawValue
        }
    }
}
