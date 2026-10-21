import Foundation
import Testing

@testable import am

@Suite("Config errors")
struct ConfigErrorTests {
    private func write(_ contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-cfg-\(UUID().uuidString).json").path
        try contents.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A decoding error on its own says nothing a user can act on, so the
    /// message names the field and where it sits.
    @Test("A missing field is named")
    func namesTheMissingField() throws {
        let file = try write(#"{"version": 1, "gateways": [{"agents": {}}]}"#)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.hint?.contains("Missing field \"id\"") == true)
    }

    @Test("A type mismatch says where")
    func reportsTypeMismatch() throws {
        let file = try write(#"{"version": "one", "gateways": []}"#)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.hint?.contains("version") == true)
    }

    @Test("A malformed secrets.json says what shape it needs")
    func secretsMustBeAnObject() throws {
        let file = try write("[]")
        let error = #expect(throws: AgentMuxError.self) { try SecretStore.load(file) }
        #expect(error?.hint?.contains("JSON object") == true)
    }

    @Test("A leftover YAML config gets its own message")
    func legacyYAMLGetsItsOwnMessage() throws {
        let root = try scratchDirectory()
        let paths = ProjectPaths(root: root)
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        try "gateways: []".write(toFile: paths.legacyYAMLFile, atomically: true, encoding: .utf8)

        let error = #expect(throws: AgentMuxError.self) { try ProjectPaths.require(from: root) }
        #expect(error?.message.contains("gateways.yaml") == true)
    }
}

@Suite("Remembering the last gateway")
struct LaunchStateTests {
    @Test("Remembered per agent, and read back")
    func remembersPerAgent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path

        LaunchState.remember(gateway: "alpha", for: .claude, in: file)
        LaunchState.remember(gateway: "beta", for: .codex, in: file)

        let state = LaunchState.load(file)
        #expect(state.lastGateway?["claude"] == "alpha")
        #expect(state.lastGateway?["codex"] == "beta")
    }

    @Test("Remembering again replaces the old choice")
    func overwritesTheSameAgent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path
        LaunchState.remember(gateway: "alpha", for: .claude, in: file)
        LaunchState.remember(gateway: "gamma", for: .claude, in: file)
        #expect(LaunchState.load(file).lastGateway?["claude"] == "gamma")
    }

    /// Remembering is a convenience, never a reason to fail a launch.
    @Test("A write that fails never fails the launch")
    func writeFailureIsSwallowed() {
        LaunchState.remember(gateway: "alpha", for: .claude, in: "/no/such/directory/state.json")
        #expect(LaunchState.load("/no/such/directory/state.json").lastGateway == nil)
    }

    @Test("A corrupt file reads as no memory at all")
    func corruptStateIsIgnored() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path
        try "{ not json".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(LaunchState.load(file).lastGateway == nil)
    }
}

/// Rules the program relies on elsewhere: break one and the failure shows up
/// somewhere far away, so each is pinned here.
@Suite("Config rules")
struct ConfigInvariantTests {
    private func scratchFile() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("am-inv-\(UUID().uuidString).json").path
    }

    private func mode(of file: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    /// The keys live in this file in the clear, so nobody else on the machine
    /// may read it.
    @Test("secrets.json is written 0600")
    func secretsAreOwnerOnly() throws {
        let file = scratchFile()
        try SecretStore.save(["k": "sk-value"], to: file)
        #expect(try mode(of: file) == 0o600)
    }

    /// An atomic write replaces the file rather than rewriting it, which drops
    /// the mode unless it is reapplied every time.
    @Test("It is still 0600 after a rewrite")
    func permissionSurvivesRewrite() throws {
        let file = scratchFile()
        try SecretStore.save(["k": "sk-one"], to: file)
        try SecretStore.write(name: "k2", value: "sk-two", to: file)
        #expect(try mode(of: file) == 0o600)
    }

    /// `-g` and the menu both address a gateway by id, so two with the same id
    /// would make the choice ambiguous.
    @Test("Duplicate gateway ids are refused, and named")
    func duplicateIdsAreRejected() throws {
        let file = scratchFile()
        try #"{"version": 1, "gateways": [{"id": "dup", "agents": {}}, {"id": "dup", "agents": {}}]}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.message.contains("dup") == true)
    }

    @Test("An unknown version is refused")
    func versionIsChecked() throws {
        let file = scratchFile()
        try #"{"version": 99, "gateways": []}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
    }
}
