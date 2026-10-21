import Foundation
import Testing

@testable import am

@Suite("am ls 的各種狀態")
struct ListStateTests {
    @Test("一個 gateway 都沒有時，告訴使用者怎麼新增")
    func emptyProject() throws {
        let paths = try projectFixture(gateways: .empty())
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("am add"))
    }

    /// Being told which key is missing is the difference between a fix and a
    /// hunt through two files.
    @Test("引用了金鑰但沒設定值時，指名是哪一把")
    func missingKeyIsNamed() throws {
        let paths = try projectFixture(secrets: [:])
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.stdout.contains("缺少金鑰"))
        #expect(run.stdout.contains("alpha_key"))
    }

    @Test("有 label 時一起顯示 id，因為 -g 要用 id")
    func labelAndIdAreBothShown() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: "我的 Gateway", agents: [
                "claude": AgentConfig(settings: [:]),
            ]),
        ]))
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.stdout.contains("我的 Gateway"))
        #expect(run.stdout.contains("alpha"))
    }

    @Test("不需要金鑰的 gateway 標示為不需金鑰")
    func noKeyNeeded() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "official", label: nil, agents: [
                "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": ""]),
            ]),
        ]))
        #expect(try runAm(["ls"], in: paths.root).stdout.contains("不需金鑰"))
    }

    @Test("路徑在目前目錄底下時顯示相對路徑")
    func pathIsShownRelative() {
        let current = FileManager.default.currentDirectoryPath
        #expect(relativeToCurrentDirectory("\(current)/a/b.json") == "a/b.json")
        #expect(relativeToCurrentDirectory("/somewhere/else.json") == "/somewhere/else.json")
    }
}

@Suite("設定檔的搜尋範圍")
struct DiscoveryBoundaryTests {
    /// Configuration is per project. Walking past the repository root would let
    /// one project silently adopt another's gateways.
    @Test("往上找會在 git root 停住")
    func stopsAtTheRepositoryRoot() throws {
        let outer = try scratchDirectory()
        try FileManager.default.createDirectory(
            atPath: ProjectPaths(root: outer).directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: ProjectPaths(root: outer).configFile)

        let inner = (outer as NSString).appendingPathComponent("repo/src")
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: ((outer as NSString).appendingPathComponent("repo") as NSString)
                .appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        #expect(ProjectPaths.discover(from: inner) == nil)
    }

    @Test("沒有 git 時，往上找得到最近的 .agentmux")
    func findsTheNearestProject() throws {
        let root = try scratchDirectory()
        try FileManager.default.createDirectory(
            atPath: ProjectPaths(root: root).directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: ProjectPaths(root: root).configFile)

        let deep = (root as NSString).appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        #expect(ProjectPaths.discover(from: deep)?.root == root)
    }

    @Test("設定檔不存在時的訊息指向 am init")
    func missingConfigPointsAtInit() throws {
        let error = #expect(throws: AgentMuxError.self) {
            try GatewayStore.load("/no/such/gateways.json")
        }
        #expect(error?.hint?.contains("am init") == true)
    }
}

@Suite("金鑰展開的邊界")
struct SecretResolutionEdgeTests {
    private func resolver(_ secrets: [String: String] = ["k": "sk-1234567890"]) -> SecretResolver {
        SecretResolver(secrets: secrets, secretsFile: "/tmp/secrets.json")
    }

    @Test("${secret: 沒有結尾時明確報錯，而不是默默接受")
    func unterminatedReferenceIsRejected() {
        #expect(throws: AgentMuxError.self) {
            try resolver().resolve("Bearer ${secret:k")
        }
    }

    /// Showing three characters of a short key would be most of it.
    @Test("太短的金鑰整個遮掉")
    func shortValuesAreFullyMasked() {
        #expect(SecretResolver.mask(value: "sk-123") == "***")
        #expect(SecretResolver.mask(value: "sk-1234567890") == "sk-...7890")
    }

    @Test("一個字串裡有多個引用時全部展開")
    func multipleReferencesInOneValue() throws {
        let resolved = try resolver(["a": "1", "b": "2"]).resolve("${secret:a}-${secret:b}")
        #expect(resolved == "1-2")
    }

    @Test("不認識的 agent 名稱會列出支援哪些")
    func unknownAgentIsNamed() {
        let error = #expect(throws: AgentMuxError.self) { try Agent.named("gemini") }
        #expect(error?.message.contains("gemini") == true)
        #expect(error?.hint?.contains("claude") == true)
    }

    @Test("啟動不存在的指令時，說的是找不到指令而不是別的")
    func missingExecutableIsReported() throws {
        let paths = try projectFixture()
        let run = try runAm(
            ["claude", "-g", "alpha"], in: paths.root,
            env: ["AGENTMUX_CLAUDE_COMMAND": "definitely-not-installed-xyz"]
        )
        #expect(run.status != 0)
        #expect(run.stderr.contains("找不到指令"))
    }
}
