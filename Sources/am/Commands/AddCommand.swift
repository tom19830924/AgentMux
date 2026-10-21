import Foundation

/// The Codex provider id defined through `-c` overrides, and the variable its
/// `env_key` points at.
private let codexProvider = "agentmux"
private let codexKeyVariable = "AGENTMUX_CODEX_KEY"

enum GatewayMode: String {
    /// A third-party endpoint, reached through a base URL.
    case custom
    /// The agent's own login; AgentMux only cancels what the project pins.
    case official
}

struct WizardAnswers {
    var agent: Agent
    var mode: GatewayMode
    var name: String
    var baseURL: String?
    /// Secret to reference, or nil when the gateway needs no key.
    var secretName: String?
    var model: String?
    var wireAPI: String?
}

/// Turns the wizard's answers into the agent block written to gateways.json.
/// Kept free of prompting so it can be tested directly.
func buildAgentConfig(_ answers: WizardAnswers) -> AgentConfig {
    let secretRef = answers.secretName.map { "${secret:\($0)}" }

    switch answers.agent {
    case .claude:
        var settings: [String: String] = [
            // An empty value cancels whatever .claude/settings.json sets, which
            // is how "use the CLI's own login" is expressed.
            "ANTHROPIC_BASE_URL": answers.mode == .official ? "" : (answers.baseURL ?? ""),
            "ANTHROPIC_AUTH_TOKEN": secretRef ?? "",
        ]
        if let model = answers.model { settings["ANTHROPIC_MODEL"] = model }
        return AgentConfig(model: answers.model, settings: settings)

    case .codex:
        var args: [String] = []
        if answers.mode == .official {
            args += ["-c", "model_provider=\"openai\""]
        } else {
            args += ["-c", "model_providers.\(codexProvider).name=\"\(answers.name)\""]
            args += ["-c", "model_providers.\(codexProvider).base_url=\"\(answers.baseURL ?? "")\""]
            args += ["-c", "model_providers.\(codexProvider).wire_api=\"\(answers.wireAPI ?? "chat")\""]
            if secretRef != nil {
                args += ["-c", "model_providers.\(codexProvider).env_key=\"\(codexKeyVariable)\""]
            }
            args += ["-c", "model_provider=\"\(codexProvider)\""]
        }
        if let model = answers.model { args += ["-c", "model=\"\(model)\""] }

        // The key travels in the environment: command lines are visible in `ps aux`.
        let env = (answers.mode == .custom ? secretRef : nil)
            .map { [codexKeyVariable: $0] }
        return AgentConfig(model: answers.model, args: args, env: env)
    }
}

private let newGatewaySentinel = "\u{0}new-gateway"
private let newSecretSentinel = "\u{0}new-secret"
private let noSecretSentinel = "\u{0}no-secret"

/// `creatingProject` is what `am init` passes: there is no `.agentmux/` yet,
/// and none is created until the wizard has run all the way through.
func addCommand(
    paths suppliedPaths: ProjectPaths? = nil, prompter: Prompter? = nil,
    creatingProject: Bool = false
) throws -> Int32 {
    let paths = try suppliedPaths ?? ProjectPaths.require()
    let scripted = prompter != nil
    if !scripted, !Terminal.isInteractive {
        throw AgentMuxError(
            "這個指令需要互動式終端機",
            hint: "請直接在終端機裡執行，或手動編輯 \(paths.configFile)"
        )
    }
    let ui = prompter ?? TerminalPrompter()

    var config = GatewayFile.empty()
    if !creatingProject { config = try GatewayStore.load(paths.configFile) }
    ui.intro(creatingProject ? "設定第一個 gateway" : "新增 gateway 設定")

    let agent = try Agent.named(
        try ui.select("要設定哪個 agent？", Agent.allCases.map {
            Choice(value: $0.id, label: $0.displayName)
        })
    )

    // Asked first: the answer decides whether a name is needed at all. The
    // official entry names itself, since there is only ever one of it per agent.
    let mode = GatewayMode(rawValue: try ui.select("要連到哪裡？", [
        Choice(value: GatewayMode.custom.rawValue, label: "第三方 gateway", hint: "自訂端點，需要 base URL"),
        Choice(value: GatewayMode.official.rawValue, label: "\(agent.displayName) 官方", hint: "用這個 CLI 原本的登入"),
    ]))!

    let gatewayID = try resolveGateway(
        config: &config, agent: agent, mode: mode, ui: ui
    )

    var baseURL: String?
    var wireAPI: String?

    if mode == .custom {
        baseURL = try ui.text(
            "Base URL",
            placeholder: agent == .codex ? "https://api.example.com/v1" : "https://api.example.com",
            defaultValue: nil
        ) { value in
            if value.isEmpty { return "這一項必填" }
            guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                return "請輸入完整的網址，例如 https://api.example.com"
            }
            return nil
        }

        if agent == .codex {
            wireAPI = try ui.select("API 形式", [
                Choice(value: "chat", label: "chat", hint: "/v1/chat/completions，多數第三方相容端點"),
                Choice(value: "responses", label: "responses", hint: "/v1/responses，OpenAI 原生"),
            ])
        }
    }

    let secret = try chooseSecret(
        config: config, gatewayID: gatewayID, mode: mode, paths: paths, ui: ui
    )

    let model = try ui.text(
        "模型（可留空）",
        placeholder: agent == .claude ? "claude-opus-5" : "gpt-5.6-luna",
        defaultValue: "",
        validate: nil
    )

    let agentConfig = buildAgentConfig(
        WizardAnswers(
            agent: agent, mode: mode, name: gatewayID, baseURL: baseURL,
            secretName: secret.name, model: model.isEmpty ? nil : model, wireAPI: wireAPI
        )
    )

    guard let index = config.gateways.firstIndex(where: { $0.id == gatewayID }) else {
        throw AgentMuxError("找不到 gateway \"\(gatewayID)\"")
    }
    config.gateways[index].agents[agent.id] = agentConfig

    // The first and only time this flow touches the disk. Up to here an
    // abandoned wizard leaves the project exactly as it was found — including
    // Ctrl-C, which kills the process outright and unwinds no `catch`.
    if creatingProject {
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        Terminal.write(
            "\(ansi.green("已建立")) \(relativeToCurrentDirectory(paths.directory))/"
                + "\(ansi.dim("（gateways.json、secrets.json 0600）"))\n"
        )
    }
    if let pending = secret.pending {
        try SecretStore.write(name: pending.name, value: pending.value, to: paths.secretsFile)
    } else if creatingProject {
        try SecretStore.save([:], to: paths.secretsFile)
    }
    try GatewayStore.save(config, to: paths.configFile)

    ui.outro("\(ansi.green("已設定")) \(gatewayID) / \(agent.id)　"
        + ansi.dim("試試 am \(agent.id) -g \(gatewayID) --dry-run"))
    return 0
}

private func resolveGateway(
    config: inout GatewayFile, agent: Agent, mode: GatewayMode, ui: Prompter
) throws -> String {
    if mode == .official {
        let id = agent.officialId
        if let existing = config.gateway(id: id) {
            try confirmOverwrite(existing, agent: agent, ui: ui)
        } else {
            config.gateways.append(Gateway(id: id, label: nil, agents: [:]))
        }
        return id
    }

    let existing = config.gateways.map(\.id)
    if existing.isEmpty {
        let name = try askGatewayName(existing: existing, ui: ui)
        config.gateways.append(Gateway(id: name, label: nil, agents: [:]))
        return name
    }

    var choices = config.gateways.map { gateway in
        Choice(
            value: gateway.id, label: gateway.id,
            hint: gateway.agents.keys.sorted().joined(separator: ", ").isEmpty
                ? "尚未設定任何 agent"
                : gateway.agents.keys.sorted().joined(separator: ", ")
        )
    }
    choices.append(Choice(value: newGatewaySentinel, label: "新增一個 gateway"))

    let chosen = try ui.select("要把 \(agent.displayName) 加到哪個 gateway？", choices)
    if chosen == newGatewaySentinel {
        let name = try askGatewayName(existing: existing, ui: ui)
        config.gateways.append(Gateway(id: name, label: nil, agents: [:]))
        return name
    }

    try confirmOverwrite(config.gateway(id: chosen)!, agent: agent, ui: ui)
    return chosen
}

private func confirmOverwrite(_ gateway: Gateway, agent: Agent, ui: Prompter) throws {
    guard gateway.agents[agent.id] != nil else { return }
    let answer = try ui.select("gateway \"\(gateway.id)\" 已經有 \(agent.id) 的設定了", [
        Choice(value: "yes", label: "覆蓋掉重新設定"),
        Choice(value: "no", label: "取消"),
    ])
    if answer == "no" { throw CancelledError() }
}

private func askGatewayName(existing: [String], ui: Prompter) throws -> String {
    try ui.text("gateway 名稱", placeholder: "my-gateway", defaultValue: nil) { value in
        if value.isEmpty { return "這一項必填" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if value.rangeOfCharacter(from: allowed.inverted) != nil
            || !(value.first?.isLetter ?? false) && !(value.first?.isNumber ?? false)
        {
            return "只能用英數字、底線與連字號（選單和 -g 都會用這個名稱）"
        }
        if existing.contains(value) { return "已經有一個叫 \"\(value)\" 的 gateway 了" }
        return nil
    }
}

/// What the wizard settled on for the key: the name the config references, and
/// the value to store when the user typed a new one. Writing is the caller's
/// job, once the whole wizard has succeeded.
struct SecretDecision {
    var name: String?
    var pending: (name: String, value: String)?
}

/// Keys are often shared: the same provider token drives both Claude and Codex.
/// Offer the ones already on disk before asking for another paste.
private func chooseSecret(
    config: GatewayFile, gatewayID: String, mode: GatewayMode,
    paths: ProjectPaths, ui: Prompter
) throws -> SecretDecision {
    let stored = try SecretStore.load(paths.secretsFile)
    let referenced = config.gateways.flatMap { gateway in
        gateway.agents.values.flatMap(secretReferencesIn)
    }
    let own = Set(config.gateway(id: gatewayID)?.agents.values.flatMap(secretReferencesIn) ?? [])
    let known = Set(stored.keys).union(referenced).sorted()

    var choices = known.map { name in
        Choice(
            value: name, label: "沿用 \(name)",
            hint: own.contains(name) ? "這個 gateway 已經在用"
                : stored[name] != nil ? "已設定" : "被引用但還沒填值"
        )
    }
    choices.append(Choice(value: newSecretSentinel, label: "輸入新的金鑰"))
    choices.append(Choice(
        value: noSecretSentinel, label: "不需要金鑰",
        hint: mode == .official ? "用 CLI 原本的登入" : nil
    ))

    let initial = own.sorted().first ?? (mode == .official ? noSecretSentinel : choices[0].value)
    let chosen = try ui.select("金鑰要用哪一把？", choices, initial: initial)

    if chosen == noSecretSentinel { return SecretDecision(name: nil, pending: nil) }
    if chosen != newSecretSentinel { return SecretDecision(name: chosen, pending: nil) }

    let name = try ui.text(
        "金鑰名稱（在 secrets.json 裡的鍵名）",
        placeholder: "\(gatewayID)_key", defaultValue: "\(gatewayID)_key"
    ) { value in
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return value.rangeOfCharacter(from: allowed.inverted) != nil
            ? "只能用英數字、底線、點與連字號" : nil
    }

    let value = try ui.password("貼上 \(name) 的值")
    return SecretDecision(name: name, pending: (name: name, value: value))
}
