import Foundation
import Testing

@testable import am

private func resolver(_ secrets: [String: String] = ["my-gateway_key": TOKEN]) -> SecretResolver {
    SecretResolver(secrets: secrets, secretsFile: "/tmp/secrets.json")
}

private func context(_ resolver: SecretResolver) -> InjectionContext {
    InjectionContext(resolver: resolver) { name in
        guard resolver.has(name) else { throw AgentMuxError("No secret named \"\(name)\"") }
        return "am secret get \(name)"
    }
}

let TOKEN = "sk-test-0123456789abcdefSECRET"

@Suite("Claude injection")
struct ClaudeInjectionTests {
    @Test("Settings ride on --settings as JSON; no file is written")
    func settingsInline() throws {
        let config = AgentConfig(settings: [
            "ANTHROPIC_BASE_URL": "https://api.example.com",
            "ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}",
        ])
        let injection = try buildClaudeInjection(config, context(resolver()))

        #expect(injection.args.first == "--settings")
        let payload = try JSONSerialization.jsonObject(
            with: Data(injection.args[1].utf8)) as! [String: Any]
        let env = payload["env"] as! [String: String]

        #expect(env["ANTHROPIC_BASE_URL"] == "https://api.example.com")
        // Emptied on purpose: this cancels whatever .claude/settings.json sets,
        // and apiKeyHelper supplies the real key on demand.
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == "")
        #expect(payload["apiKeyHelper"] as? String == "am secret get my-gateway_key")
    }

    @Test("The key never reaches the command line")
    func noSecretInArgs() throws {
        let config = AgentConfig(settings: ["ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}"])
        let injection = try buildClaudeInjection(config, context(resolver()))
        #expect(!injection.args.joined(separator: " ").contains(TOKEN))
    }

    @Test("Official mode neutralises with empty strings and no helper")
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

    @Test("A missing key fails immediately")
    func missingSecret() {
        let config = AgentConfig(settings: ["ANTHROPIC_AUTH_TOKEN": "${secret:nope}"])
        #expect(throws: AgentMuxError.self) {
            try buildClaudeInjection(config, context(resolver()))
        }
    }
}

@Suite("Codex injection")
struct CodexInjectionTests {
    @Test("-c arguments keep their order; the key stays in the environment")
    func argsAndEnv() throws {
        let config = AgentConfig(
            args: ["-c", "model_providers.agentmux.env_key=\"AGENTMUX_CODEX_KEY\"",
                   "-c", "model_provider=\"agentmux\""],
            env: ["AGENTMUX_CODEX_KEY": "${secret:my-gateway_key}"]
        )
        let injection = try buildCodexInjection(config, context(resolver()))

        #expect(injection.args == [
            "-c", "model_providers.agentmux.env_key=\"AGENTMUX_CODEX_KEY\"",
            "-c", "model_provider=\"agentmux\"",
        ])
        #expect(injection.env["AGENTMUX_CODEX_KEY"] == TOKEN)
        #expect(!injection.args.joined(separator: " ").contains(TOKEN))
    }

    @Test("A settings field is refused")
    func rejectsSettings() {
        let config = AgentConfig(settings: ["ANYTHING": "x"])
        #expect(throws: AgentMuxError.self) {
            try buildCodexInjection(config, context(resolver()))
        }
    }
}

@Suite("Handling secrets")
struct SecretTests {
    @Test("Expanding, masking, detecting")
    func resolveAndMask() throws {
        let subject = resolver()
        #expect(try subject.resolve("Bearer ${secret:my-gateway_key}") == "Bearer \(TOKEN)")
        #expect(subject.containsSecret("x \(TOKEN) y"))
        #expect(subject.mask(TOKEN).contains("(secret:my-gateway_key)"))
        #expect(!subject.mask(TOKEN).contains(TOKEN))
    }

    @Test("Finding referenced names without expanding them")
    func references() {
        #expect(secretReferences(in: "${secret:a} and ${secret:b}") == ["a", "b"])
        #expect(secretReferences(in: "nothing").isEmpty)
    }

    @Test("Only a whole-field reference goes to apiKeyHelper")
    func wholeReference() {
        #expect(wholeSecretReference("${secret:k}") == "k")
        #expect(wholeSecretReference("Bearer ${secret:k}") == nil)
        #expect(wholeSecretReference("plain") == nil)
    }
}
