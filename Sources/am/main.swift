import Foundation

func helpText() -> String {
    let agents = Agent.allCases
        .map { "  \($0.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.displayName) \(ansi.dim("(\($0.injectionSummary))"))" }
        .joined(separator: "\n")

    return """
    \(ansi.bold("am")) — per-project gateway switcher for AI agents

    Usage:
      am init                      Create .agentmux/ and set up the first gateway
      am add                       Add a gateway, or another agent to one you have
      am ls                        List this project's gateways
      am secret get <name>         Print one key (Claude Code calls this itself)
      am <agent> [options] [-- …]  Pick a gateway, then start the agent

    Agents:
    \(agents)

    Options:
      -g, --gateway <id>   Skip the menu and use this gateway
          --dry-run        Print what would be injected, without starting anything
      -h, --help           Show this help
      -v, --version        Show the version

    Examples:
      am add                       One key can serve several agents; it offers to reuse
      am claude                    Pick from the menu and land straight in Claude Code
      am claude -g my-gateway      Name the gateway instead
      am codex -- --resume         Everything after -- is handed to codex untouched

    Running claude or codex directly is unaffected: they read their own settings as before.

    """
}

func run(_ argv: [String]) throws -> Int32 {
    // Everything after `--` belongs to the agent and is never interpreted here.
    let separator = argv.firstIndex(of: "--")
    let own = separator.map { Array(argv[..<$0]) } ?? argv
    let passthrough = separator.map { Array(argv[($0 + 1)...]) } ?? []

    guard let first = own.first else {
        Terminal.write(helpText())
        return 0
    }
    let rest = Array(own.dropFirst())

    switch first {
    case "-h", "--help":
        Terminal.write(helpText())
        return 0
    case "-v", "--version":
        Terminal.write("\(Build.version)\n")
        return 0
    case "init":
        return try initCommand()
    case "add":
        return try addCommand()
    case "ls":
        return try listCommand()
    case "secret":
        guard rest.first == "get" else {
            throw AgentMuxError(
                "Usage: am secret get <name>",
                hint: "Claude Code's apiKeyHelper runs this to fetch a key"
            )
        }
        return try secretGetCommand(Array(rest.dropFirst()))
    default:
        break
    }

    guard Agent.isAgent(first) else {
        throw AgentMuxError(
            "Unknown command \"\(first)\"",
            hint: "Commands are init, add, ls and secret, or the name of an agent"
                + " (\(Agent.allCases.map(\.id).joined(separator: ", ")))"
        )
    }

    var options = RunOptions(passthrough: passthrough)
    var index = 0
    while index < rest.count {
        let argument = rest[index]
        switch argument {
        case "-g", "--gateway":
            guard index + 1 < rest.count else {
                throw AgentMuxError("\(argument) needs a gateway id after it")
            }
            options.gateway = rest[index + 1]
            index += 2
        case "--dry-run":
            options.dryRun = true
            index += 1
        default:
            if argument.hasPrefix("--gateway=") {
                options.gateway = String(argument.dropFirst("--gateway=".count))
                index += 1
                continue
            }
            throw AgentMuxError(
                "am does not know the option \"\(argument)\"",
                hint: "To pass it to \(first), put it after --: am \(first) -- \(argument)"
            )
        }
    }

    return try runCommand(agentId: first, options: options, prompter: TerminalPrompter())
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let error as AgentMuxError {
    FileHandle.standardError.write(Data("\(ansi.red("Error")) \(error.message)\n".utf8))
    if let hint = error.hint {
        FileHandle.standardError.write(Data("\(ansi.dim(hint))\n".utf8))
    }
    exit(1)
} catch is CancelledError {
    FileHandle.standardError.write(Data("\(ansi.dim("Cancelled"))\n".utf8))
    exit(130)
} catch {
    FileHandle.standardError.write(Data("\(ansi.red("Error")) \(error)\n".utf8))
    exit(1)
}
