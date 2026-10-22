import Foundation

/// `am secret get` is deliberately absent from this: it exists because
/// Claude Code's `apiKeyHelper` takes a shell command and something has to
/// print the key, not because anyone is meant to type it. Listing it among the
/// commands invites the question "what is that for?", and every honest answer
/// is "nothing, for you".
func helpText() -> String {
    let agents = Agent.allCases
        .map { "  \($0.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.displayName) \(ansi.dim("(\($0.injectionSummary))"))" }
        .joined(separator: "\n")

    return """
    \(ansi.bold("am")) — per-project gateway switcher for AI agents

    Usage:
      am init                               Create .agentmux/ and set up the first gateway
      am add                                Add a gateway, or another agent to one you have
      am ls                                 List this project's gateways
      am [options] <agent> [its own args]   Pick a gateway and start that agent
      am -h, am --help                      Show this help
      am -v, am --version                   Show the version

    Agents:
    \(agents)

    Options (before the agent's name):
      -g, --gateway <id>   Skip the menu and use this gateway
          --gateway=<id>   The same, written as one word
          --dry-run        Print what would be injected, without starting anything
          --link           Keep this agent's config inside .agentmux/, linked back
          --unlink         Remove a link am made, leaving what it points at

    One of --dry-run, --link and --unlink at a time: each ends the run somewhere
    different. Only --dry-run takes a gateway: linking only rearranges
    directories, and which gateway you use is settled at launch.

    The agent's name ends am's own arguments. Everything after it is handed to
    the agent untouched, whatever it looks like — which is why the two CLIs can
    spell the same idea differently and both just work.

    Examples:
      am add                       One key can serve several agents; it offers to reuse
      am claude                    Pick from the menu and land straight in Claude Code
      am -g my-gateway claude      Name the gateway instead
      am claude --resume <id>      Everything after the agent is the agent's own
      am codex resume <id>         Codex spells the same thing as a subcommand
      am --link claude             am's own flags go before the agent too

    Running claude or codex directly is unaffected: they read their own settings as before.

    """
}

func run(_ argv: [String]) throws -> Int32 {
    guard let first = argv.first else {
        Terminal.write(helpText())
        return 0
    }

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
        let rest = Array(argv.dropFirst())
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

    // A word that is neither a command nor an agent is a mistyped command, and
    // the list of real ones is more use than anything the agent scan can say.
    guard first.hasPrefix("-") || Agent.isAgent(first) else {
        throw AgentMuxError(
            "Unknown command \"\(first)\"",
            hint: "Commands are init, add, ls and secret, or the name of an agent"
                + " (\(Agent.allCases.map(\.id).joined(separator: ", ")))"
        )
    }

    let (agentId, own, passthrough) = try splitAtAgent(argv)

    var options = RunOptions(mode: try runMode(from: own), passthrough: passthrough)
    var index = 0
    while index < own.count {
        let argument = own[index]
        switch argument {
        case "-g", "--gateway":
            guard index + 1 < own.count else {
                throw AgentMuxError("\(argument) needs a gateway id after it")
            }
            options.gateway = own[index + 1]
            index += 2
        case _ where runModeFlags.contains(where: { $0.flag == argument }):
            index += 1  // already settled by runMode(from:)
        default:
            if argument.hasPrefix("--gateway=") {
                options.gateway = String(argument.dropFirst("--gateway=".count))
                index += 1
                continue
            }
            throw AgentMuxError(
                "am does not know the option \"\(argument)\"",
                hint: "am's own options come before the agent; anything after it "
                    + "is the agent's. To pass this to \(agentId): am \(agentId) \(argument)"
            )
        }
    }

    // Neither mode chooses a gateway, so naming one is a misunderstanding
    // rather than a preference to honour quietly.
    if options.mode == .link || options.mode == .unlink, options.gateway != nil {
        throw AgentMuxError(
            "\(options.mode == .link ? "--link" : "--unlink") takes no gateway",
            hint: "Linking puts an agent's own configuration inside .agentmux/; "
                + "which gateway you use is a separate question, settled at launch"
        )
    }

    // Neither starts the agent, so arguments meant for it would go nowhere.
    // Dropping them quietly would hide a command line that did not do what it
    // looks like it did. --dry-run is not here: it stands in for a launch, so
    // what it prints has to include them.
    if options.mode == .link || options.mode == .unlink, !passthrough.isEmpty {
        throw AgentMuxError(
            "\(options.mode == .link ? "--link" : "--unlink") does not start \(agentId), "
                + "so it has nothing to do with \(passthrough.joined(separator: " "))",
            hint: "Run it on its own: am \(options.mode == .link ? "--link" : "--unlink") \(agentId)"
        )
    }

    return try runCommand(agentId: agentId, options: options, prompter: TerminalPrompter())
}

/// Splits the command line at the agent's name.
///
/// The agent's name is the last word that belongs to `am`: everything after it
/// is the agent's own and is never read here, which is what lets
/// `am claude --resume <id>` and `am codex resume <id>` both work although the
/// two CLIs spell the same idea differently.
///
/// The scan has to know that `-g` takes a value, because that value may itself
/// be an agent's name: in `am -g claude claude` the first one is a gateway.
func splitAtAgent(_ argv: [String]) throws
    -> (agent: String, own: [String], passthrough: [String])
{
    var index = 0
    while index < argv.count {
        if Agent.isAgent(argv[index]) {
            var passthrough = Array(argv[(index + 1)...])
            // `--` used to be the separator. Swallowing one keeps the commands
            // people already have working, rather than handing the agent an
            // argument it never asked for.
            if passthrough.first == "--" { passthrough.removeFirst() }
            return (argv[index], Array(argv[..<index]), passthrough)
        }
        guard argv[index] == "-g" || argv[index] == "--gateway" else {
            index += 1
            continue
        }
        // Said here rather than left to the option loop: without the value the
        // scan cannot tell where am's own arguments end, so it never gets there.
        guard index + 1 < argv.count else {
            throw AgentMuxError("\(argv[index]) needs a gateway id after it")
        }
        index += 2
    }

    throw AgentMuxError(
        "No agent to start",
        hint: "am's own options come first and the agent last: "
            + "am [options] <\(Agent.allCases.map(\.id).joined(separator: "|"))> "
            + "[the agent's own arguments]"
    )
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
