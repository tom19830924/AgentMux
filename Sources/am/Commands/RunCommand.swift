import Foundation

struct RunOptions {
    var gateway: String?
    /// Print what would be injected instead of starting the agent.
    var dryRun = false
    var passthrough: [String] = []
}

/// Picks a gateway and hands the process over to the agent.
func runCommand(agentId: String, options: RunOptions, prompter: Prompter) throws -> Int32 {
    let agent = try Agent.named(agentId)
    let paths = try ProjectPaths.require()
    let config = try GatewayStore.load(paths.configFile)

    guard !config.gateways.isEmpty else {
        throw AgentMuxError("No gateways are set up", hint: "Run `am add` to create one")
    }

    let candidates = config.gateways(supporting: agent)
    guard !candidates.isEmpty else {
        throw AgentMuxError(
            "No gateway in \(paths.configFile) supports \(agent.id)",
            hint: "Run `am add` to add \(agent.id) to one of them"
        )
    }

    let gateway = try chooseGateway(
        agent: agent, candidates: candidates, config: config,
        options: options, paths: paths, prompter: prompter
    )

    let resolver = try SecretResolver(file: paths.secretsFile)
    let context = InjectionContext(
        resolver: resolver,
        // Claude Code only: Codex's status line cannot run a command, and the
        // fields below are named after Anthropic's variables either way.
        statusLine: config.statusLine == true && agent == .claude
            ? statusLineCommand(
                for: gateway, config: gateway.agents[agent.id]!,
                colour: ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            )
            : nil
    ) { name in
        // Fail here rather than letting the agent start and its helper fail
        // later, where the error would be buried inside the agent's own output.
        guard resolver.has(name) else {
            throw AgentMuxError(
                "No secret named \"\(name)\"",
                hint: "Add \"\(name)\": \"<key>\" to \(paths.secretsFile)"
            )
        }
        return secretHelperCommand(secretsFile: paths.secretsFile, name: name)
    }

    let injection = try agent.build(gateway.agents[agent.id]!, context)
    let args = injection.args + options.passthrough

    // Command lines are world-readable through `ps`; a secret must never reach one.
    for argument in args where resolver.containsSecret(argument) {
        throw AgentMuxError(
            "Gateway \"\(gateway.id)\" would put a key on the command line",
            hint: "Command lines are visible in `ps aux`. For Claude, make the whole "
                + "ANTHROPIC_AUTH_TOKEN value ${secret:name}; for Codex, put the key "
                + "in `env` and point env_key at it"
        )
    }

    if options.dryRun {
        printDryRun(command: agent.command, args: args, env: injection.env, resolver: resolver)
        return 0
    }

    LaunchState.remember(gateway: gateway.id, for: agent, in: paths.stateFile)
    try execAgent(command: agent.command, args: args, env: injection.env)
}

private func chooseGateway(
    agent: Agent, candidates: [Gateway], config: GatewayFile,
    options: RunOptions, paths: ProjectPaths, prompter: Prompter
) throws -> Gateway {
    if let requested = options.gateway {
        guard let gateway = config.gateway(id: requested) else {
            throw AgentMuxError(
                "No gateway named \"\(requested)\"",
                hint: "Available: \(config.gateways.map(\.id).joined(separator: ", "))"
            )
        }
        guard gateway.agents[agent.id] != nil else {
            throw AgentMuxError(
                "Gateway \"\(gateway.id)\" has no \(agent.id) set up",
                hint: "Available: \(candidates.map(\.id).joined(separator: ", "))"
            )
        }
        return gateway
    }

    guard Terminal.isInteractive else {
        throw AgentMuxError(
            "No terminal here, so there is no menu to show",
            hint: "Name the gateway with -g, for example: am -g \(candidates[0].id) \(agent.id)"
        )
    }

    let last = LaunchState.load(paths.stateFile).lastGateway?[agent.id]
    let chosen = try prompter.select(
        "Choose a gateway for \(agent.displayName)",
        candidates.map {
            Choice(value: $0.id, label: $0.displayName)
        },
        initial: last
    )
    return config.gateway(id: chosen)!
}

/// The command Claude Code runs to fetch a key. It re-invokes this binary, so
/// the key is read from secrets.json on demand instead of being handed over up
/// front. Only the secret's name appears here, never its value.
func secretHelperCommand(secretsFile: String, name: String) -> String {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return [executable, "secret", "get", "--file", secretsFile, name]
        .map(shellQuote)
        .joined(separator: " ")
}

/// What the status line says: which gateway this session is on, under whose
/// key, and where that actually points.
///
/// All three are known before the agent starts, so the line needs nothing
/// from the session and the command stays a `printf` — no reading stdin, no
/// parser, nothing to install.
///
/// A field is left out when the gateway has nothing to put in it, so "use the
/// CLI's own login" shows a name and no more rather than empty labels.
func statusLineFields(gateway: Gateway, config: AgentConfig) -> [(label: String, value: String)] {
    var fields = [(label: "gateway", value: gateway.displayName)]
    let settings = config.settings ?? [:]

    if let token = settings["ANTHROPIC_AUTH_TOKEN"], let name = wholeSecretReference(token) {
        fields.append((label: "key", value: name))
    }

    // The host, not the whole URL: the path is noise, and a base URL holding a
    // reference to a secret must not be resolved into something on display.
    if let raw = settings["ANTHROPIC_BASE_URL"], !raw.isEmpty,
       !raw.contains("${secret:"), let host = URL(string: raw)?.host
    {
        fields.append((label: "host", value: host))
    }
    return fields
}

/// Turns those fields into the command Claude Code runs to draw them.
///
/// Labels and separators live in the format string, which is ours; every value
/// is a separate argument, so a `%` or a quote in a gateway's label cannot
/// become syntax. Labels carry no escape of their own, which leaves them in
/// the grey Claude Code already paints the status line, with only the values
/// coloured — the contrast is what makes them readable.
///
/// Colours are written as `\033` for `printf` to expand rather than as literal
/// control bytes, so what `am` puts on the command line stays legible in `ps`.
///
/// `colour` is the caller's to decide: this runs in the agent's terminal, not
/// in ours, so whether our own stdout is a terminal says nothing about it.
func statusLineCommand(for gateway: Gateway, config: AgentConfig, colour: Bool) -> String {
    let fields = statusLineFields(gateway: gateway, config: config)
    let format = fields
        .map { colour ? "\($0.label): \\033[36m%s\\033[0m" : "\($0.label): %s" }
        .joined(separator: ", ")
    let arguments = fields.map { shellQuote($0.value) }.joined(separator: " ")
    return "printf '\(format)' \(arguments)"
}

/// Quotes a string for the single shell command handed to an agent.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func printDryRun(
    command: String, args: [String], env: [String: String], resolver: SecretResolver
) {
    var lines: [String] = []

    if !env.isEmpty {
        lines.append(ansi.bold("env:"))
        for key in env.keys.sorted() {
            lines.append("  \(key) = \(resolver.mask(env[key]!))")
        }
    }

    var remaining = args
    if let index = args.firstIndex(of: "--settings"), index + 1 < args.count {
        lines.append(ansi.bold("--settings (passed inline; no file is written):"))
        lines.append(contentsOf: prettyJSON(args[index + 1]).map { "  \($0)" })
        remaining.removeSubrange(index...(index + 1))
    }

    lines.append(ansi.bold("Command line:"))
    let settingsNote = args.contains("--settings") ? " --settings <the JSON above>" : ""
    let rest = remaining.isEmpty ? "" : " " + remaining.joined(separator: " ")
    lines.append("  \(command)\(settingsNote)\(rest)")
    lines.append(ansi.dim("Nothing was started."))

    Terminal.write(lines.joined(separator: "\n") + "\n")
}

private func prettyJSON(_ raw: String) -> [String] {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(
              withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          )
    else { return [raw] }
    return String(decoding: pretty, as: UTF8.self).components(separatedBy: "\n")
}
