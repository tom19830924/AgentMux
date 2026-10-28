import Foundation
import Testing

@testable import am

/// Replays a fixed list of answers, recording what the flow asked so a test can
/// assert on the questions as well as the result.
final class ScriptedPrompter: Prompter {
    private(set) var asked: [String] = []
    private var queue: [String]

    init(_ answers: [String]) { self.queue = answers }

    /// Plain output the command printed, in order, so a test can assert on
    /// what the user was actually told.
    private(set) var notes: [String] = []

    func intro(_: String) {}
    func outro(_: String) {}
    func note(_ message: String) { notes.append(message) }

    private func take(_ message: String) throws -> String {
        asked.append(message)
        guard !queue.isEmpty else {
            throw AgentMuxError("The script ran out, but the flow is still asking: \(message)")
        }
        return queue.removeFirst()
    }

    func select(_ message: String, _ choices: [Choice], initial: String?) throws -> String {
        let answer = try take(message)
        guard let match = choices.first(where: { $0.value == answer || $0.label.contains(answer) })
        else {
            throw AgentMuxError(
                "\"\(message)\" has no option matching \"\(answer)\": \(choices.map(\.label).joined(separator: " / "))"
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

@Suite("Overwriting what is there")
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

    @Test("An agent already set up asks before being replaced")
    func asksBeforeOverwriting() throws {
        let paths = try existing()
        let ui = ScriptedPrompter(["claude", "A third-party gateway", "alpha", "Cancel"])
        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(ui.asked.contains { $0.contains("already has claude set up") })
    }

    /// Cancelling has to leave the old settings exactly as they were, or the
    /// confirmation would be worse than useless.
    @Test("Cancelling leaves the old settings exactly as they were")
    func cancellingKeepsTheOldSettings() throws {
        let paths = try existing()
        let ui = ScriptedPrompter(["claude", "A third-party gateway", "alpha", "Cancel"])
        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }

        let config = try GatewayStore.load(paths.configFile)
        let settings = config.gateway(id: "alpha")?.agents["claude"]?.settings
        #expect(settings?["ANTHROPIC_BASE_URL"] == "https://old.example.com")
    }

    @Test("Replacing writes the new settings")
    func overwritingReplacesThem() throws {
        let paths = try existing()
        let ui = ScriptedPrompter([
            "claude", "A third-party gateway", "alpha", "Replace it",
            "https://new.example.com", "Reuse alpha_key",
        ])
        #expect(try addCommand(paths: paths, prompter: ui) == 0)

        let config = try GatewayStore.load(paths.configFile)
        let settings = config.gateway(id: "alpha")?.agents["claude"]?.settings
        #expect(settings?["ANTHROPIC_BASE_URL"] == "https://new.example.com")
    }
}

@Suite("Abandoning the wizard")
struct AbortTests {
    /// `init` used to create the directory and two empty files before asking
    /// anything, so a Ctrl-C left a project that `am init` then refused to
    /// touch again ("already exists") while holding no usable gateway.
    @Test("Abandoning init leaves no .agentmux/")
    func initLeavesNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-abort-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: root)

        // Answers run out at "Paste the value …": the script ends mid-wizard, the
        // same place an interrupted run would stop.
        let ui = ScriptedPrompter([
            "claude", "A third-party gateway", "my-gateway",
            "https://api.example.com", "Enter a new key", "my-gateway_key",
        ])

        #expect(throws: (any Error).self) {
            try addCommand(paths: paths, prompter: ui, creatingProject: true)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.directory))
    }

    /// The key used to be written the moment it was pasted, which put a secret
    /// on disk for a gateway that was never finished.
    @Test("A key pasted before abandoning is not stored")
    func abortedSecretIsNotStored() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude", "A third-party gateway", "my-gateway",
            "https://api.example.com", "Enter a new key", "my-gateway_key",
        ])

        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(try SecretStore.load(paths.secretsFile).isEmpty)
        #expect(try GatewayStore.load(paths.configFile).gateways.isEmpty)
    }

    @Test("Abandoning touches nothing that was already there")
    func existingConfigSurvives() throws {
        let paths = try scratchProject(
            GatewayFile(version: 1, gateways: [Gateway(id: "keep", label: nil, agents: [:])]),
            secrets: ["old_key": "sk-old"]
        )
        let ui = ScriptedPrompter(["claude", "A third-party gateway", "Add a new gateway", "later"])

        #expect(throws: (any Error).self) { try addCommand(paths: paths, prompter: ui) }
        #expect(try GatewayStore.load(paths.configFile).gateways.map(\.id) == ["keep"])
        #expect(try SecretStore.load(paths.secretsFile) == ["old_key": "sk-old"])
    }
}

@Suite("Wizard: first run")
struct FirstRunTests {
    @Test("A finished run leaves a working gateway, key only in secrets.json")
    func firstGateway() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude",                   // which agent
            "custom",                   // where to connect
            "my-gateway",               // gateway name
            "https://api.example.com",  // base URL
            "Enter a new key",          // where the key comes from
            "",                         // keep the default name, my-gateway_key
            "sk-real-token-value",      // the key itself
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

    @Test("The official choice asks for neither name nor base URL")
    func officialNeedsNoName() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter(["claude", "official", "No key needed", ""])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)
        #expect(!ui.asked.contains { $0.contains("Gateway name") })
        #expect(!ui.asked.contains { $0.contains("Base URL") })

        let config = try GatewayStore.load(paths.configFile)
        #expect(config.gateway(id: "anthropic")?.agents["claude"]?
            .settings?["ANTHROPIC_BASE_URL"] == "")
    }

    @Test("It asks where to connect before it asks for a name")
    func asksDestinationFirst() throws {
        let paths = try scratchProject()
        let ui = ScriptedPrompter([
            "claude", "custom", "gw", "https://api.example.com", "No key needed", "",
        ])
        _ = try addCommand(paths: paths, prompter: ui)

        let destination = ui.asked.firstIndex { $0.contains("Connect to what?") }
        let name = ui.asked.firstIndex { $0.contains("Gateway name") }
        #expect(destination != nil && name != nil)
        #expect(destination! < name!)
    }
}

@Suite("Wizard: one key, several agents")
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

    @Test("Adding codex to a gateway reuses its key without a repaste")
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
        #expect(!ui.asked.contains { $0.contains("Paste the value") })
    }

    @Test("Reusing an existing key is the first option offered")
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
                if m.contains("Which key?") { onSecretQuestion(c) }
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
        #expect(secretChoices.first?.label.contains("Reuse") == true)
    }

    @Test("Another provider means another key")
    func separateKeys() throws {
        let paths = try projectWithClaude()
        let ui = ScriptedPrompter([
            "claude", "custom", "Add a new gateway", "other", "https://api.other.ai",
            "Enter a new key", "other_key", "sk-other-token", "",
        ])

        #expect(try addCommand(paths: paths, prompter: ui) == 0)
        #expect(try SecretStore.load(paths.secretsFile) == [
            "my-gateway_key": "sk-shared-token", "other_key": "sk-other-token",
        ])
    }
}

@Suite("What the wizard writes")
struct WizardConfigTests {
    @Test("A custom Claude endpoint references the key, never inlines it")
    func claudeCustom() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .claude, mode: .custom, name: "my-gateway",
            baseURL: "https://api.example.com", secretName: "my-gateway_key",
            wireAPI: nil
        ))
        #expect(config.settings?["ANTHROPIC_AUTH_TOKEN"] == "${secret:my-gateway_key}")
    }

    @Test("A custom Codex endpoint takes its key through env_key")
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
    @Test("The provider id is the gateway name, so /status can tell them apart")
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

    @Test("A different gateway name gives a different provider id")
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

    @Test("Official Codex goes back to the built-in provider, with no env")
    func codexOfficial() {
        let config = buildAgentConfig(WizardAnswers(
            agent: .codex, mode: .official, name: "openai",
            baseURL: nil, secretName: nil, wireAPI: nil
        ))
        #expect(config.args == ["-c", "model_provider=\"openai\""])
        #expect(config.env == nil)
    }
}
