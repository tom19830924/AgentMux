import Foundation

/// The variable the Codex provider's `env_key` points at. The provider's id is
/// the gateway's own name: `codex /status` prints that id, so sharing one id
/// across every gateway would make the line say the same thing no matter which
/// one was picked.
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
        return AgentConfig(settings: settings)

    case .codex:
        var args: [String] = []
        if answers.mode == .official {
            args += ["-c", "model_provider=\"openai\""]
        } else {
            let provider = answers.name
            args += ["-c", "model_providers.\(provider).name=\"\(answers.name)\""]
            args += ["-c", "model_providers.\(provider).base_url=\"\(answers.baseURL ?? "")\""]
            args += ["-c", "model_providers.\(provider).wire_api=\"\(answers.wireAPI ?? "chat")\""]
            if secretRef != nil {
                args += ["-c", "model_providers.\(provider).env_key=\"\(codexKeyVariable)\""]
            }
            args += ["-c", "model_provider=\"\(provider)\""]
        }

        // The key travels in the environment: command lines are visible in `ps aux`.
        let env = (answers.mode == .custom ? secretRef : nil)
            .map { [codexKeyVariable: $0] }
        return AgentConfig(args: args, env: env)
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
            "This command needs an interactive terminal",
            hint: "Run it in a terminal, or edit \(paths.configFile) by hand"
        )
    }
    let ui = prompter ?? TerminalPrompter()

    var config = GatewayFile.empty()
    if !creatingProject { config = try GatewayStore.load(paths.configFile) }
    ui.intro(creatingProject ? "Set up the first gateway" : "Add a gateway")

    let agent = try Agent.named(
        try ui.select("Which agent?", Agent.allCases.map {
            Choice(value: $0.id, label: $0.displayName)
        })
    )

    // Asked first: the answer decides whether a name is needed at all. The
    // official entry names itself, since there is only ever one of it per agent.
    let mode = GatewayMode(rawValue: try ui.select("Connect to what?", [
        Choice(value: GatewayMode.custom.rawValue, label: "A third-party gateway", hint: "Your own endpoint; needs a base URL"),
        Choice(value: GatewayMode.official.rawValue, label: "\(agent.displayName) itself", hint: "Use the CLI's own login"),
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
            if value.isEmpty { return "Required" }
            guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                return "Enter a full URL, for example https://api.example.com"
            }
            return nil
        }

        if agent == .codex {
            wireAPI = try ui.select("API shape", [
                Choice(value: "chat", label: "chat", hint: "/v1/chat/completions, what most third parties speak"),
                Choice(value: "responses", label: "responses", hint: "/v1/responses, OpenAI's own"),
            ])
        }
    }

    let secret = try chooseSecret(
        config: config, gatewayID: gatewayID, mode: mode, paths: paths, ui: ui
    )


    let agentConfig = buildAgentConfig(
        WizardAnswers(
            agent: agent, mode: mode, name: gatewayID, baseURL: baseURL,
            secretName: secret.name, wireAPI: wireAPI
        )
    )

    guard let index = config.gateways.firstIndex(where: { $0.id == gatewayID }) else {
        throw AgentMuxError("No gateway named \"\(gatewayID)\"")
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
            "\(ansi.green("Created")) \(relativeToCurrentDirectory(paths.directory))/"
                + "\(ansi.dim(" (gateways.json, secrets.json 0600)"))\n"
        )
    }
    if let pending = secret.pending {
        try SecretStore.write(name: pending.name, value: pending.value, to: paths.secretsFile)
    } else if creatingProject {
        try SecretStore.save([:], to: paths.secretsFile)
    }
    try GatewayStore.save(config, to: paths.configFile)

    ui.outro("\(ansi.green("Ready")) \(gatewayID) / \(agent.id)   "
        + ansi.dim("try am \(agent.id)"))
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
                ? "No agents set up yet"
                : gateway.agents.keys.sorted().joined(separator: ", ")
        )
    }
    choices.append(Choice(value: newGatewaySentinel, label: "Add a new gateway"))

    let chosen = try ui.select("Add \(agent.displayName) to which gateway?", choices)
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
    let answer = try ui.select("\"\(gateway.id)\" already has \(agent.id) set up", [
        Choice(value: "yes", label: "Replace it"),
        Choice(value: "no", label: "Cancel"),
    ])
    if answer == "no" { throw CancelledError() }
}

private func askGatewayName(existing: [String], ui: Prompter) throws -> String {
    try ui.text("Gateway name", placeholder: "my-gateway", defaultValue: nil) { value in
        if value.isEmpty { return "Required" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if value.rangeOfCharacter(from: allowed.inverted) != nil
            || !(value.first?.isLetter ?? false) && !(value.first?.isNumber ?? false)
        {
            return "Letters, digits, underscores and hyphens only (the menu and -g both use this)"
        }
        if existing.contains(value) { return "There is already a gateway called \"\(value)\"" }
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
            value: name, label: "Reuse \(name)",
            hint: own.contains(name) ? "Already used by this gateway"
                : stored[name] != nil ? "Stored" : "Referenced, but has no value yet"
        )
    }
    choices.append(Choice(value: newSecretSentinel, label: "Enter a new key"))
    choices.append(Choice(
        value: noSecretSentinel, label: "No key needed",
        hint: mode == .official ? "Uses the CLI's own login" : nil
    ))

    let initial = own.sorted().first ?? (mode == .official ? noSecretSentinel : choices[0].value)
    let chosen = try ui.select("Which key?", choices, initial: initial)

    if chosen == noSecretSentinel { return SecretDecision(name: nil, pending: nil) }
    if chosen != newSecretSentinel { return SecretDecision(name: chosen, pending: nil) }

    let name = try ui.text(
        "Name for this key (the key name inside secrets.json)",
        placeholder: "\(gatewayID)_key", defaultValue: "\(gatewayID)_key"
    ) { value in
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return value.rangeOfCharacter(from: allowed.inverted) != nil
            ? "Letters, digits, underscores, dots and hyphens only" : nil
    }

    let value = try ui.password("Paste the value for \(name)")
    return SecretDecision(name: name, pending: (name: name, value: value))
}
