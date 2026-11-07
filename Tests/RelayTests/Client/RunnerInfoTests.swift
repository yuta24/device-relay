import Foundation
@testable import Relay
import Testing

struct RunnerInfoTests {
    @Test func writesOwnerOnlyFileAndReadsItBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let info = RunnerInfo(url: "http://[fd00::1]:8100/", token: RunnerAuth.generateToken(), udid: "DEVICE")

        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(json?["url"] == "http://[fd00::1]:8100/")
    }

    @Test func replacesLooserExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])

        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM")
        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func writeFailureThrowsAndKeepsWhatIsInTheWay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let marker = url.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())

        #expect(throws: SetupError.self) {
            try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: url)
        }
        RunnerInfo.remove(at: url)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func removeDeletesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM").write(to: url)
        RunnerInfo.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// relay start --background, relay status, and relay stop. UDIDs and names are dummies.

struct RunnerInfoProcessTests {
    @Test func savesNamePidAndStartTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        let info = RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM", name: "iPhone 17 Pro",
                              pid: 1234, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try info.write(to: url)
        #expect(try RunnerInfo.read(from: url) == info)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["startedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(json?["pid"] as? Int == 1234)
    }

    @Test func readsAFileWithoutThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RunnerInfo.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"url":"http://127.0.0.1:8100/","token":"t","udid":"SIM"}"#.utf8).write(to: url)
        let info = try RunnerInfo.read(from: url)
        #expect(info == RunnerInfo(url: "http://127.0.0.1:8100/", token: "t", udid: "SIM"))
        #expect(RelayProcess.runningRelayStart(info) == nil)
    }
}
