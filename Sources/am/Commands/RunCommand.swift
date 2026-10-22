import Foundation

/// What the run is for. Each of these ends somewhere different, so asking for
/// two of them asks for two different things — which an enum cannot hold, and
/// so cannot be left for a later branch to resolve by accident.
enum RunMode: Equatable {
    /// Hand the process over to the agent.
    case launch
    /// Print the injection instead.
    case dryRun
    /// Write it where the agent's own tooling reads it.
    case link
    /// Take that back out.
    case unlink
}

/// The flags that name a mode, paired with the mode they name.
///
/// The parser reads this; the help text spells the same flags out by hand,
/// because a generated list cannot say what each one is for. What keeps the
/// two together is a test that every flag here appears in `--help`.
let runModeFlags: [(flag: String, mode: RunMode)] = [
    ("--dry-run", .dryRun),
    ("--link", .link),
    ("--unlink", .unlink),
]

/// Works out the mode from the arguments, refusing two that disagree.
///
/// These are only the arguments before the agent's name — `splitAtAgent` has
/// already set the agent's own aside — so a flag of the same name there is the
/// agent's business and never reaches this.
func runMode(from arguments: [String]) throws -> RunMode {
    var chosen: (flag: String, mode: RunMode)?
    for argument in arguments {
        guard let found = runModeFlags.first(where: { $0.flag == argument }) else { continue }
        if let chosen, chosen.mode != found.mode {
            throw AgentMuxError(
                "\(chosen.flag) and \(found.flag) ask for different things",
                hint: "Pick one of \(runModeFlags.map(\.flag).joined(separator: ", "))"
            )
        }
        chosen = found
    }
    return chosen?.mode ?? .launch
}

struct RunOptions {
    var gateway: String?
    var mode: RunMode = .launch
    var passthrough: [String] = []
}

/// Picks a gateway and hands the process over to the agent.
func runCommand(agentId: String, options: RunOptions, prompter: Prompter) throws -> Int32 {
    let agent = try Agent.named(agentId)
    let paths = try ProjectPaths.require()

    // Neither needs a gateway, and both do the same thing for every agent, so
    // neither has to wait for one to be configured first.
    switch options.mode {
    case .link:
        let preparation = try prepareLink(for: agent, paths: paths, prompter: prompter)
        return try writeLink(for: agent, paths: paths, preparation: preparation)
    case .unlink:
        return try unlinkDirectory(for: agent, paths: paths)
    default:
        break
    }

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
    let context = InjectionContext(resolver: resolver) { name in
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

    if options.mode == .dryRun {
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
