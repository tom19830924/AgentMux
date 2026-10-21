import Foundation
import Testing

@testable import am

@Suite("設定檔的錯誤訊息")
struct ConfigErrorTests {
    private func write(_ contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-cfg-\(UUID().uuidString).json").path
        try contents.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A decoding error on its own says nothing a user can act on, so the
    /// message names the field and where it sits.
    @Test("缺少欄位時指出是哪個欄位")
    func namesTheMissingField() throws {
        let file = try write(#"{"version": 1, "gateways": [{"agents": {}}]}"#)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.hint?.contains("缺少欄位 \"id\"") == true)
    }

    @Test("型別不符時指出位置")
    func reportsTypeMismatch() throws {
        let file = try write(#"{"version": "一", "gateways": []}"#)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.hint?.contains("version") == true)
    }

    @Test("secrets.json 不是物件時給出可照做的提示")
    func secretsMustBeAnObject() throws {
        let file = try write("[]")
        let error = #expect(throws: AgentMuxError.self) { try SecretStore.load(file) }
        #expect(error?.hint?.contains("JSON 物件") == true)
    }

    @Test("只有舊版 YAML 時，提示改用 JSON 而不是說找不到設定")
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

@Suite("上次選過的 gateway")
struct LaunchStateTests {
    @Test("記住之後讀得回來，而且分 agent 記")
    func remembersPerAgent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path

        LaunchState.remember(gateway: "alpha", for: .claude, in: file)
        LaunchState.remember(gateway: "beta", for: .codex, in: file)

        let state = LaunchState.load(file)
        #expect(state.lastGateway?["claude"] == "alpha")
        #expect(state.lastGateway?["codex"] == "beta")
    }

    @Test("同一個 agent 再記一次會覆蓋")
    func overwritesTheSameAgent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path
        LaunchState.remember(gateway: "alpha", for: .claude, in: file)
        LaunchState.remember(gateway: "gamma", for: .claude, in: file)
        #expect(LaunchState.load(file).lastGateway?["claude"] == "gamma")
    }

    /// Remembering is a convenience, never a reason to fail a launch.
    @Test("寫不進去也不會讓啟動失敗")
    func writeFailureIsSwallowed() {
        LaunchState.remember(gateway: "alpha", for: .claude, in: "/no/such/directory/state.json")
        #expect(LaunchState.load("/no/such/directory/state.json").lastGateway == nil)
    }

    @Test("檔案壞掉時當作沒有紀錄，不是整個爆掉")
    func corruptStateIsIgnored() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-state-\(UUID().uuidString).json").path
        try "{ 壞掉的".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(LaunchState.load(file).lastGateway == nil)
    }
}

/// Rules the program relies on elsewhere: break one and the failure shows up
/// somewhere far away, so each is pinned here.
@Suite("設定檔的規則")
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
    @Test("secrets.json 寫出來就是 0600")
    func secretsAreOwnerOnly() throws {
        let file = scratchFile()
        try SecretStore.save(["k": "sk-value"], to: file)
        #expect(try mode(of: file) == 0o600)
    }

    /// An atomic write replaces the file rather than rewriting it, which drops
    /// the mode unless it is reapplied every time.
    @Test("再寫一次仍然是 0600")
    func permissionSurvivesRewrite() throws {
        let file = scratchFile()
        try SecretStore.save(["k": "sk-one"], to: file)
        try SecretStore.write(name: "k2", value: "sk-two", to: file)
        #expect(try mode(of: file) == 0o600)
    }

    /// `-g` and the menu both address a gateway by id, so two with the same id
    /// would make the choice ambiguous.
    @Test("重複的 gateway id 會被擋下，並指出是哪一個")
    func duplicateIdsAreRejected() throws {
        let file = scratchFile()
        try #"{"version": 1, "gateways": [{"id": "dup", "agents": {}}, {"id": "dup", "agents": {}}]}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        let error = #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
        #expect(error?.message.contains("dup") == true)
    }

    @Test("version 不是 1 就拒絕讀取")
    func versionIsChecked() throws {
        let file = scratchFile()
        try #"{"version": 99, "gateways": []}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        #expect(throws: AgentMuxError.self) { try GatewayStore.load(file) }
    }
}
