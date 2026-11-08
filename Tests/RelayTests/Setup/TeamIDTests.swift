import Foundation
@testable import Relay
import Testing

struct TeamIDTests {
  @Test func parsesFindIdentity() {
    #expect(SigningIdentities.parseFindIdentity(findIdentityOutput) == [
      SigningIdentity(sha1: certificateSHA1, name: "Apple Development: Test User (ABCDE12345)"),
      SigningIdentity(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", name: "Developer ID Application: Test User (TEAM000001)")
    ])
    #expect(SigningIdentities.parseFindIdentity("     0 valid identities found\n").isEmpty)
  }

  @Test func readsTheTeamFromTheCertificateSubject() throws {
    let certificates = SigningIdentities.parseFindCertificate(findCertificateOutput)
    let der = try #require(certificates[certificateSHA1])
    #expect(SigningIdentities.organizationalUnits(certificate: der) == ["TEAM000001"])
    #expect(SigningIdentities.organizationalUnits(certificate: Data([0x30, 0x00])).isEmpty)
  }

  @Test func loadsDevelopmentIdentitiesWithTheirTeams() throws {
    // The Developer ID identity is not for development, and the person ID in the name is not the team.
    #expect(try SigningIdentities.load(FakeHost().commands) == [
      SigningIdentity(sha1: certificateSHA1, name: "Apple Development: Test User (ABCDE12345)", teamID: "TEAM000001")
    ])
  }

  @Test func prefersOptionThenConfigThenKeychain() throws {
    let identities = [SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001")]
    let fromOption = try TeamIDResolver.resolve(explicit: "TEAM000003", config: RelayConfig(teamID: "TEAM000002")) { identities }
    #expect(fromOption.teamID == "TEAM000003" && fromOption.source == .option)
    let fromConfig = try TeamIDResolver.resolve(explicit: nil, config: RelayConfig(teamID: "TEAM000002")) { identities }
    #expect(fromConfig.teamID == "TEAM000002" && fromConfig.source == .config)
    let fromKeychain = try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }
    #expect(fromKeychain.teamID == "TEAM000001" && fromKeychain.source == .keychain)
  }

  @Test func certificatesOfOneTeamAreNotAmbiguous() throws {
    let identities = [
      SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001"),
      SigningIdentity(sha1: "B", name: "Apple Development: B", teamID: "TEAM000001")
    ]
    #expect(try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }.teamID == "TEAM000001")
  }

  @Test func refusesToGuessBetweenTeams() {
    let identities = [
      SigningIdentity(sha1: "A", name: "Apple Development: A", teamID: "TEAM000001"),
      SigningIdentity(sha1: "B", name: "Apple Development: B", teamID: "TEAM000002")
    ]
    #expect {
      try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { identities }
    } throws: { error in
      String(describing: error).contains("TEAM000001  Apple Development: A") && String(describing: error).contains("TEAM000002")
    }
    #expect(throws: SetupError.self) { try TeamIDResolver.resolve(explicit: nil, config: RelayConfig()) { [] } }
  }

  @Test func validatesTeamIDs() {
    #expect(RelayConfig.isValidTeamID("ABCDE12345"))
    #expect(!RelayConfig.isValidTeamID("ABCDE1234"))
    #expect(!RelayConfig.isValidTeamID("abcde12345"))
  }

  @Test func configCommandSetsGetsAndUnsets() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = RelayConfig.defaultURL(home: directory)
    #expect(try RelayConfig.read(from: url) == RelayConfig())

    var lines: [String] = []
    #expect(ConfigCommand.run(ConfigOptions(action: .get("teamID")), url: url) { lines.append($0) } == 1)
    #expect(ConfigCommand.run(ConfigOptions(action: .set("teamID", "ABCDE12345")), url: url) == 0)
    #expect(try RelayConfig.read(from: url).teamID == "ABCDE12345")
    #expect(ConfigCommand.run(ConfigOptions(action: .get("teamID")), url: url) { lines.append($0) } == 0)
    #expect(lines == ["ABCDE12345"])
    #expect(ConfigCommand.run(ConfigOptions(action: .unset("teamID")), url: url) == 0)
    #expect(try RelayConfig.read(from: url).teamID == nil)
  }
}
