import Foundation
import Testing

@testable import am

/// What Claude Code's `apiKeyHelper` runs. Its whole job is to hand one value
/// to a pipe, so the shape of its output is part of the contract.
@Suite("am secret get")
struct SecretGetTests {
    private func project(_ secrets: [String: String]) throws -> ProjectPaths {
        let root = try scratchDirectory()
        let paths = ProjectPaths(root: root)
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: paths.configFile)
        try SecretStore.save(secrets, to: paths.secretsFile)
        return paths
    }

    /// A trailing newline would be taken as part of the key by whatever reads it.
    @Test("印出金鑰，結尾不加換行")
    func printsTheValueVerbatim() throws {
        let paths = try project(["k": "sk-value"])
        let run = try runAm(["secret", "get", "--file", paths.secretsFile, "k"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout == "sk-value")
    }

    @Test("--file 省略時從專案找")
    func findsTheProjectSecrets() throws {
        let paths = try project(["k": "sk-from-project"])
        let run = try runAm(["secret", "get", "k"], in: paths.root)
        #expect(run.stdout == "sk-from-project")
    }

    @Test("找不到名稱時報錯，而且不吐出任何值")
    func missingNameFails() throws {
        let paths = try project(["k": "sk-value"])
        let run = try runAm(["secret", "get", "--file", paths.secretsFile, "nope"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("nope"))
    }

    @Test("--file 後面沒接路徑時給出用法")
    func fileNeedsAPath() throws {
        let root = try scratchDirectory()
        let run = try runAm(["secret", "get", "--file"], in: root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("--file"))
    }
}

@Suite("命令列外觀")
struct CommandSurfaceTests {
    @Test("--help 列出每個指令")
    func helpListsTheCommands() throws {
        let root = try scratchDirectory()
        let run = try runAm(["--help"], in: root)
        #expect(run.status == 0)
        for command in ["am init", "am add", "am ls", "am secret get"] {
            #expect(run.stdout.contains(command))
        }
    }

    @Test("--help 不提到任何特定的服務商")
    func helpNamesNoProvider() throws {
        let root = try scratchDirectory()
        let run = try runAm(["--help"], in: root)
        #expect(!run.stdout.lowercased().contains("mixroute"))
    }

    @Test("am ls 列出 gateway、agent 與引用到的金鑰名稱，但不印金鑰")
    func listShowsTheShape() throws {
        let root = try scratchDirectory()
        let paths = ProjectPaths(root: root)
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(
            GatewayFile(version: 1, gateways: [
                Gateway(id: "alpha", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.example.com",
                        "ANTHROPIC_AUTH_TOKEN": "${secret:alpha_key}",
                    ])
                ])
            ]),
            to: paths.configFile
        )
        try SecretStore.save(["alpha_key": "sk-must-not-appear"], to: paths.secretsFile)

        let run = try runAm(["ls"], in: root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("alpha"))
        #expect(run.stdout.contains("claude"))
        #expect(run.stdout.contains("alpha_key"))
        #expect(!run.stdout.contains("sk-must-not-appear"))
    }

    @Test("沒有設定檔時 am ls 說要先 init")
    func listWithoutAProject() throws {
        let run = try runAm(["ls"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("am init"))
    }
}

/// The helper command is embedded in a JSON settings blob and later run by a
/// shell, so anything unusual in a path has to survive the round trip.
@Suite("shell 引號處理")
struct ShellQuoteTests {
    @Test("一般字串加上單引號")
    func plainValue() {
        #expect(shellQuote("abc") == "'abc'")
    }

    @Test("空白不會讓參數被拆開")
    func spaces() {
        #expect(shellQuote("/path/with space/am") == "'/path/with space/am'")
    }

    @Test("單引號本身被正確跳脫")
    func singleQuote() {
        let quoted = shellQuote("it's")
        #expect(quoted == "'it'\\''s'")
    }

    @Test("helper 指令帶著金鑰名稱，但不含金鑰")
    func helperMentionsOnlyTheName() {
        let command = secretHelperCommand(secretsFile: "/tmp/s.json", name: "alpha_key")
        #expect(command.contains("alpha_key"))
        #expect(command.contains("secret"))
        #expect(command.contains("/tmp/s.json"))
    }
}
