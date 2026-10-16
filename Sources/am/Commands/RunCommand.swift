import Foundation

struct RunOptions {
    var gateway: String?
    var dryRun: Bool = false
    var passthrough: [String] = []
}

/// Picks a gateway and hands the process over to the agent.
func runCommand(agentId: String, options: RunOptions, prompter: Prompter) throws -> Int32 {
    let agent = try Agent.named(agentId)
    let paths = try ProjectPaths.require()
    let config = try GatewayStore.load(paths.configFile)

    guard !config.gateways.isEmpty else {
        throw AgentMuxError("還沒有設定任何 gateway", hint: "執行 `am add` 新增一個")
    }

    let candidates = config.gateways(supporting: agent)
    guard !candidates.isEmpty else {
        throw AgentMuxError(
            "\(paths.configFile) 裡沒有任何 gateway 支援 \(agent.id)",
            hint: "執行 `am add` 替某個 gateway 加上 \(agent.id)"
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
                "找不到 secret \"\(name)\"",
                hint: "請在 \(paths.secretsFile) 加上 \"\(name)\": \"<金鑰>\""
            )
        }
        return secretHelperCommand(secretsFile: paths.secretsFile, name: name)
    }

    let injection = try agent.build(gateway.agents[agent.id]!, context)
    let args = injection.args + options.passthrough

    // Command lines are world-readable through `ps`; a secret must never reach one.
    for argument in args where resolver.containsSecret(argument) {
        throw AgentMuxError(
            "gateway \"\(gateway.id)\" 會把金鑰放進命令列參數",
            hint: "命令列在 `ps aux` 裡看得到。Claude 的 ANTHROPIC_AUTH_TOKEN 請整格寫成 "
                + "${secret:名稱}；Codex 請把金鑰放在 env 並用 env_key 指向它"
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
                "沒有名為 \"\(requested)\" 的 gateway",
                hint: "可用的有：\(config.gateways.map(\.id).joined(separator: ", "))"
            )
        }
        guard gateway.agents[agent.id] != nil else {
            throw AgentMuxError(
                "gateway \"\(gateway.id)\" 沒有設定 \(agent.id)",
                hint: "可用的有：\(candidates.map(\.id).joined(separator: ", "))"
            )
        }
        return gateway
    }

    guard Terminal.isInteractive else {
        throw AgentMuxError(
            "不是互動式終端機，無法顯示選單",
            hint: "請用 -g 指定 gateway，例如：am \(agent.id) -g \(candidates[0].id)"
        )
    }

    let last = LaunchState.load(paths.stateFile).lastGateway?[agent.id]
    let chosen = try prompter.select(
        "選擇 gateway（\(agent.displayName)）",
        candidates.map {
            Choice(value: $0.id, label: $0.displayName, hint: $0.agents[agent.id]?.model)
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
        lines.append(ansi.bold("--settings（直接帶在命令列，不產生檔案）:"))
        lines.append(contentsOf: prettyJSON(args[index + 1]).map { "  \($0)" })
        remaining.removeSubrange(index...(index + 1))
    }

    lines.append(ansi.bold("命令列:"))
    let settingsNote = args.contains("--settings") ? " --settings <上面那段>" : ""
    let rest = remaining.isEmpty ? "" : " " + remaining.joined(separator: " ")
    lines.append("  \(command)\(settingsNote)\(rest)")
    lines.append(ansi.dim("未啟動。"))

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
