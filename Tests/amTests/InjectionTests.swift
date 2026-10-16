import Foundation
import Testing

@testable import am

private func resolver(_ secrets: [String: String] = ["mixroute_key": TOKEN]) -> SecretResolver {
    SecretResolver(secrets: secrets, secretsFile: "/tmp/secrets.json")
}

private func context(_ resolver: SecretResolver) -> InjectionContext {
    InjectionContext(resolver: resolver) { name in
        guard resolver.has(name) else { throw AgentMuxError("找不到 secret \"\(name)\"") }
        return "am secret get \(name)"
    }
}

let TOKEN = "sk-test-0123456789abcdefSECRET"

@Suite("Claude 注入")
struct ClaudeInjectionTests {
    @Test("設定以 JSON 帶在 --settings 上，不產生檔案")
    func settingsInline() throws {
        let config = AgentConfig(settings: [
            "ANTHROPIC_BASE_URL": "https://api.mixroute.ai",
            "ANTHROPIC_AUTH_TOKEN": "${secret:mixroute_key}",
        ])
        let injection = try buildClaudeInjection(config, context(resolver()))

        #expect(injection.args.first == "--settings")
        let payload = try JSONSerialization.jsonObject(
            with: Data(injection.args[1].utf8)) as! [String: Any]
        let env = payload["env"] as! [String: String]

        #expect(env["ANTHROPIC_BASE_URL"] == "https://api.mixroute.ai")
        // Emptied on purpose: this cancels whatever .claude/settings.json sets,
        // and apiKeyHelper supplies the real key on demand.
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == "")
        #expect(payload["apiKeyHelper"] as? String == "am secret get mixroute_key")
    }

    @Test("金鑰不出現在命令列")
    func noSecretInArgs() throws {
        let config = AgentConfig(settings: ["ANTHROPIC_AUTH_TOKEN": "${secret:mixroute_key}"])
        let injection = try buildClaudeInjection(config, context(resolver()))
        #expect(!injection.args.joined(separator: " ").contains(TOKEN))
    }

    @Test("官方模式用空字串中和，且沒有 apiKeyHelper")
    func officialNeutralises() throws {
        let config = AgentConfig(settings: [
            "ANTHROPIC_BASE_URL": "", "ANTHROPIC_AUTH_TOKEN": "",
        ])
        let injection = try buildClaudeInjection(config, context(resolver()))
        let payload = try JSONSerialization.jsonObject(
            with: Data(injection.args[1].utf8)) as! [String: Any]

        #expect((payload["env"] as! [String: String])["ANTHROPIC_BASE_URL"] == "")
        #expect(payload["apiKeyHelper"] == nil)
    }

    @Test("缺少金鑰時當場報錯")
    func missingSecret() {
        let config = AgentConfig(settings: ["ANTHROPIC_AUTH_TOKEN": "${secret:nope}"])
        #expect(throws: AgentMuxError.self) {
            try buildClaudeInjection(config, context(resolver()))
        }
    }
}

@Suite("Codex 注入")
struct CodexInjectionTests {
    @Test("-c 參數原樣保留順序，金鑰只走環境變數")
    func argsAndEnv() throws {
        let config = AgentConfig(
            args: ["-c", "model_providers.agentmux.env_key=\"AGENTMUX_CODEX_KEY\"",
                   "-c", "model_provider=\"agentmux\""],
            env: ["AGENTMUX_CODEX_KEY": "${secret:mixroute_key}"]
        )
        let injection = try buildCodexInjection(config, context(resolver()))

        #expect(injection.args == [
            "-c", "model_providers.agentmux.env_key=\"AGENTMUX_CODEX_KEY\"",
            "-c", "model_provider=\"agentmux\"",
        ])
        #expect(injection.env["AGENTMUX_CODEX_KEY"] == TOKEN)
        #expect(!injection.args.joined(separator: " ").contains(TOKEN))
    }

    @Test("settings 欄位會被擋下")
    func rejectsSettings() {
        let config = AgentConfig(settings: ["ANYTHING": "x"])
        #expect(throws: AgentMuxError.self) {
            try buildCodexInjection(config, context(resolver()))
        }
    }
}

@Suite("金鑰處理")
struct SecretTests {
    @Test("展開、遮蔽、偵測")
    func resolveAndMask() throws {
        let subject = resolver()
        #expect(try subject.resolve("Bearer ${secret:mixroute_key}") == "Bearer \(TOKEN)")
        #expect(subject.containsSecret("x \(TOKEN) y"))
        #expect(subject.mask(TOKEN).contains("(secret:mixroute_key)"))
        #expect(!subject.mask(TOKEN).contains(TOKEN))
    }

    @Test("找出引用的名稱而不展開")
    func references() {
        #expect(secretReferences(in: "${secret:a} and ${secret:b}") == ["a", "b"])
        #expect(secretReferences(in: "nothing").isEmpty)
    }

    @Test("只有整格是引用時才交給 apiKeyHelper")
    func wholeReference() {
        #expect(wholeSecretReference("${secret:k}") == "k")
        #expect(wholeSecretReference("Bearer ${secret:k}") == nil)
        #expect(wholeSecretReference("plain") == nil)
    }
}
