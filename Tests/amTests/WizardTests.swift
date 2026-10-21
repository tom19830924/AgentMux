import Foundation
import Testing

@testable import am

/// Replays a fixed list of answers, recording what the flow asked so a test can
/// assert on the questions as well as the result.
final class ScriptedPrompter: Prompter {
    private(set) var asked: [String] = []
    private var queue: [String]

    init(_ answers: [String]) { self.queue = answers }

    func intro(_: String) {}
    func outro(_: String) {}

    private func take(_ message: String) throws -> String {
        asked.append(message)
        guard !queue.isEmpty else {
            throw AgentMuxError("腳本用完了，但流程還在問：\(message)")
        }
        return queue.removeFirst()
    }

    func select(_ message: String, _ choices: [Choice], initial: String?) throws -> String {
        let answer = try take(message)
        guard let match = choices.first(where: { $0.value == answer || $0.label.contains(answer) })
        else {
            throw AgentMuxError(
                "「\(message)」沒有符合 \"\(answer)\" 的選項：\(choices.map(\.label).joined(separator: " / "))"
            )
        }
        return match.value
    }

    func text(_ message: String, placeholder _: String?, defaultValue: String?,
              validate _: ((String) -> String?)?) throws -> String
    {
        let answer = try take(message)
        return answer.isEmpty ? (defaultValue ?? "") : answer
    }

    func password(_ message: String) throws -> String { try take(message) }
}

private func scratchProject(
    _ config: GatewayFile = .empty(), secrets: [String: String] = [:]
) throws -> ProjectPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("am-wiz-\(UUID().uuidString)").path
    let paths = ProjectPaths(root: root)
    try FileManager.default.createDirectory(atPath: paths.directory, withIntermediateDirectories: true)
    try GatewayStore.save(config, to: paths.configFile)
    try SecretStore.save(secrets, to: paths.secretsFile)
    return paths
}

@Suite("覆蓋既有設定")
struct OverwriteTests {
    private func existing() throws -> ProjectPaths {
        try scratchProject(
            GatewayFile(version: 1, gateways: [
                Gateway(id: "alpha", label: nil, agents: [
                    "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": "https://old.example.com"]),
                ]),
            ]),
            secrets: ["alpha_key": "sk-old"]
        )
    }

    @Test("已經設定過的 agent 會先問要不要覆蓋")
    func asksBeforeOverwriting() throws {
        let paths = try existing()
        let ui = ScriptedPrompter(["claude", "第三方 gateway", "alpha", "取消"])
        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(ui.asked.contains { $0.contains("已經有 claude 的設定") })
    }

    /// Cancelling has to leave the old settings exactly as they were, or the
    /// confirmation would be worse than useless.
    @Test("選取消時既有設定原封不動")
    func cancellingKeepsTheOldSettings() throws {
        let paths = try existing()
        let ui = ScriptedPrompter(["claude", "第三方 gateway", "alpha", "取消"])
        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }

        let config = try GatewayStore.load(paths.configFile)
        let settings = config.gateway(id: "alpha")?.agents["claude"]?.settings
        #expect(settings?["ANTHROPIC_BASE_URL"] == "https://old.example.com")
    }

    @Test("選覆蓋時換成新的設定")
    func overwritingReplacesThem() throws {
        let paths = try existing()
        let ui = ScriptedPrompter([
            "claude", "第三方 gateway", "alpha", "覆蓋掉重新設定",
            "https://new.example.com", "沿用 alpha_key",
        ])
        #expect(try addCommand(paths: paths, prompter: ui) == 0)

        let config = try GatewayStore.load(paths.configFile)
        let settings = config.gateway(id: "alpha")?.agents["claude"]?.settings
        #expect(settings?["ANTHROPIC_BASE_URL"] == "https://new.example.com")
    }
}

@Suite("精靈中斷")
struct AbortTests {
    /// `init` used to create the directory and two empty files before asking
    /// anything, so a Ctrl-C left a project that `am init` then refused to
    /// touch again ("已經存在") while holding no usable gateway.
    @Test("init 中途放棄，不留下 .agentmux/")
    func initLeavesNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-abort-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: root)

        // Answers run out at "貼上 ... 的值": the script ends mid-wizard, the
        // same place an interrupted run would stop.
        let ui = ScriptedPrompter([
            "claude", "第三方 gateway", "my-gateway",
            "https://api.example.com", "輸入新的金鑰", "my-gateway_key",
        ])

        #expect(throws: (any Error).self) {
            try addCommand(paths: paths, prompter: ui, creatingProject: true)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.directory))
    }

    /// The key used to be written the moment it was pasted, which put a secret
    /// on disk for a gateway that was never finished.
    @Test("放棄時貼過的金鑰不會留在 secrets.json")
    func abortedSecretIsNotStored() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude", "第三方 gateway", "my-gateway",
            "https://api.example.com", "輸入新的金鑰", "my-gateway_key",
        ])

        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(try SecretStore.load(paths.secretsFile).isEmpty)
        #expect(try GatewayStore.load(paths.configFile).gateways.isEmpty)
    }

    @Test("放棄時不會動到既有設定")
    func existingConfigSurvives() throws {
        let paths = try scratchProject(
            GatewayFile(version: 1, gateways: [Gateway(id: "keep", label: nil, agents: [:])]),
            secrets: ["old_key": "sk-old"]
        )
        let ui = ScriptedPrompter(["claude", "第三方 gateway", "新增一個 gateway", "later"])

        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(try GatewayStore.load(paths.configFile).gateways.map(\.id) == ["keep"])
        #expect(try SecretStore.load(paths.secretsFile) == ["old_key": "sk-old"])
    }
}

@Suite("精靈：第一次設定")
struct FirstRunTests {
    @Test("跑完流程就有一個能用的 gateway，金鑰只進 secrets.json")
    func firstGateway() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude",                   // 哪個 agent
            "custom",                   // 要連到哪裡
            "my-gateway",                 // gateway 名稱
            "https://api.example.com",  // base URL
            "輸入新的金鑰",              // 金鑰來源
            "",                         // 名稱用預設 my-gateway_key
            "sk-real-token-value",      // 金鑰
        ])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)

        let config = try GatewayStore.load(paths.configFile)
        let claude = config.gateway(id: "my-gateway")?.agents["claude"]
        #expect(claude?.settings?["ANTHROPIC_BASE_URL"] == "https://api.example.com")
        #expect(claude?.settings?["ANTHROPIC_AUTH_TOKEN"] == "${secret:my-gateway_key}")

        let raw = try String(contentsOfFile: paths.configFile, encoding: .utf8)
        #expect(!raw.contains("sk-real-token-value"))
        #expect(try SecretStore.load(paths.secretsFile) == ["my-gateway_key": "sk-real-token-value"])
    }

    @Test("官方不問名稱也不問 base URL")
    func officialNeedsNoName() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter(["claude", "official", "不需要金鑰", ""])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)
        #expect(!ui.asked.contains { $0.contains("名稱") })
        #expect(!ui.asked.contains { $0.contains("Base URL") })

        let config = try GatewayStore.load(paths.configFile)
        #expect(config.gateway(id: "anthropic")?.agents["claude"]?
            .settings?["ANTHROPIC_BASE_URL"] == "")
    }

    @Test("先問連到哪裡，再問名稱")
    func asksDestinationFirst() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude", "custom", "gw", "https://api.example.com", "不需要金鑰", "",
        ])
        _ = try addCommand(paths: paths, prompter: ui)

        let destination = ui.asked.firstIndex { $0.contains("要連到哪裡") }
        let name = ui.asked.firstIndex { $0.contains("名稱") }
        #expect(destination != nil && name != nil)
        #expect(destination! < name!)
    }
}

@Suite("精靈：同一把金鑰給多個 agent")
struct SharedKeyTests {
    private func projectWithClaude() throws -> ProjectPaths {
        try scratchProject(
            GatewayFile(version: 1, gateways: [
                Gateway(id: "my-gateway", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.example.com",
                        "ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}",
                    ]),
                ]),
            ]),
            secrets: ["my-gateway_key": "sk-shared-token"]
        )
    }

    @Test("加 codex 到既有 gateway 並沿用同一把金鑰，不必重貼")
    func reuseKey() throws {
        let paths = try projectWithClaude()
        let ui = ScriptedPrompter([
            "codex", "custom", "my-gateway", "https://api.example.com/v1",
            "chat", "my-gateway_key", "gpt-5.6-luna",
        ])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)

        let config = try GatewayStore.load(paths.configFile)
        let codex = config.gateway(id: "my-gateway")?.agents["codex"]
        #expect(codex?.env?["AGENTMUX_CODEX_KEY"] == "${secret:my-gateway_key}")
        // Nothing new was written, and the flow never asked to paste a key.
        #expect(try SecretStore.load(paths.secretsFile) == ["my-gateway_key": "sk-shared-token"])
        #expect(!ui.asked.contains { $0.contains("貼上") })
    }

    @Test("沿用現有金鑰是選單裡的第一個選項")
    func reuseIsOffered() throws {
        let paths = try projectWithClaude()
        var secretChoices: [Choice] = []

        final class Spy: Prompter {
            let inner: ScriptedPrompter
            let onSecretQuestion: ([Choice]) -> Void
            init(_ inner: ScriptedPrompter, _ onSecretQuestion: @escaping ([Choice]) -> Void) {
                self.inner = inner
                self.onSecretQuestion = onSecretQuestion
            }
            func intro(_ m: String) { inner.intro(m) }
            func outro(_ m: String) { inner.outro(m) }
            func select(_ m: String, _ c: [Choice], initial: String?) throws -> String {
                if m.contains("金鑰") { onSecretQuestion(c) }
                return try inner.select(m, c, initial: initial)
            }
            func text(_ m: String, placeholder: String?, defaultValue: String?,
                      validate: ((String) -> String?)?) throws -> String {
                try inner.text(m, placeholder: placeholder, defaultValue: defaultValue, validate: validate)
            }
            func password(_ m: String) throws -> String { try inner.password(m) }
        }

        let ui = Spy(ScriptedPrompter([
            "codex", "custom", "my-gateway", "https://api.example.com/v1",
            "chat", "my-gateway_key", "",
        ])) { secretChoices = $0 }

        _ = try addCommand(paths: paths, prompter: ui)
        #expect(secretChoices.first?.value == "my-gateway_key")
        #expect(secretChoices.first?.label.contains("沿用") == true)
    }

    @Test("另一個 provider 就是另一把金鑰")
    func separateKeys() throws {
        let paths = try projectWithClaude()
        let ui = ScriptedPrompter([
            "claude", "custom", "新增一個 gateway", "other", "https://api.other.ai",
            "輸入新的金鑰", "other_key", "sk-other-token", "",
        ])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)
        #expect(try SecretStore.load(paths.secretsFile) == [
            "my-gateway_key": "sk-shared-token", "other_key": "sk-other-token",
        ])
    }
}

@Suite("精靈產生的設定")
struct WizardConfigTests {
    @Test("claude 自訂端點用 ${secret:} 引用，不寫明文")
    func claudeCustom() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .claude, mode: .custom, name: "my-gateway",
            baseURL: "https://api.example.com", secretName: "my-gateway_key",
            wireAPI: nil
        ))
        #expect(config.settings?["ANTHROPIC_AUTH_TOKEN"] == "${secret:my-gateway_key}")
    }

    @Test("codex 自訂端點：金鑰走 env_key，不進命令列")
    func codexCustom() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .codex, mode: .custom, name: "my-gateway",
            baseURL: "https://api.example.com/v1", secretName: "my-gateway_key",
            wireAPI: "chat"
        ))
        let args = config.args ?? []
        #expect(args.contains("model_providers.my-gateway.base_url=\"https://api.example.com/v1\""))
        #expect(args.contains("model_providers.my-gateway.wire_api=\"chat\""))
        #expect(args.contains("model_providers.my-gateway.env_key=\"AGENTMUX_CODEX_KEY\""))
        #expect(config.env == ["AGENTMUX_CODEX_KEY": "${secret:my-gateway_key}"])
        #expect(!args.joined(separator: " ").contains("${secret:"))
    }

    /// Codex's `/status` prints the provider's id — the key the table is
    /// defined under — not its `name` field. Registering every gateway under
    /// one shared id made that line read "agentmux" whichever gateway the user
    /// had picked, which is the one thing it is there to tell them.
    @Test("provider id 就是 gateway 名稱，/status 才顯示得出選了哪個")
    func providerIdIsTheGatewayName() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .codex, mode: .custom, name: "mixroute",
            baseURL: "https://api.example.com/v1", secretName: "mixroute_key",
            wireAPI: "chat"
        ))
        let args = config.args ?? []
        #expect(args.contains("model_provider=\"mixroute\""))
        #expect(args.contains("model_providers.mixroute.base_url=\"https://api.example.com/v1\""))
        #expect(!args.joined(separator: " ").contains("agentmux"))
    }

    @Test("換一個 gateway 名稱，provider id 跟著換")
    func anotherGatewayGetsItsOwnId() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .codex, mode: .custom, name: "openrouter",
            baseURL: "https://openrouter.ai/api/v1", secretName: "openrouter_key",
            wireAPI: "chat"
        ))
        let args = config.args ?? []
        #expect(args.contains("model_provider=\"openrouter\""))
        #expect(args.contains("model_providers.openrouter.name=\"openrouter\""))
    }

    @Test("codex 官方切回內建 provider，不帶環境變數")
    func codexOfficial() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .codex, mode: .official, name: "openai",
            baseURL: nil, secretName: nil, wireAPI: nil
        ))
        #expect(config.args == ["-c", "model_provider=\"openai\""])
        #expect(config.env == nil)
    }
}
