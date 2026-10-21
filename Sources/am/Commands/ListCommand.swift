import Foundation

func listCommand() throws -> Int32 {
    let paths = try ProjectPaths.require()
    let config = try GatewayStore.load(paths.configFile)
    let secrets = try SecretStore.load(paths.secretsFile)

    var lines = [ansi.dim(relativeToCurrentDirectory(paths.configFile)), ""]

    guard !config.gateways.isEmpty else {
        Terminal.write("\(ansi.dim("No gateways yet — run")) am add \(ansi.dim("to create one"))\n")
        return 0
    }

    for gateway in config.gateways {
        // The id is only worth repeating when a hand-written label differs from it.
        lines.append(
            gateway.displayName == gateway.id
                ? ansi.bold(gateway.id)
                : "\(ansi.bold(gateway.displayName)) \(ansi.dim("(\(gateway.id))"))"
        )

        for agent in Agent.allCases {
            guard let agentConfig = gateway.agents[agent.id] else { continue }

            let referenced = Set(secretReferencesIn(agentConfig))
            let missing = referenced.filter { secrets[$0] == nil }.sorted()
            let status: String
            if referenced.isEmpty {
                status = ansi.dim("no key needed")
            } else if missing.isEmpty {
                status = ansi.green("key set (\(referenced.sorted().joined(separator: ", ")))")
            } else {
                status = ansi.red("missing key: \(missing.joined(separator: ", "))")
            }

            lines.append("  \(agent.id.padding(toLength: 7, withPad: " ", startingAt: 0))  \(status)")
        }
        lines.append("")
    }

    Terminal.write(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    return 0
}

func secretReferencesIn(_ config: AgentConfig) -> [String] {
    let values = Array((config.settings ?? [:]).values)
        + Array((config.env ?? [:]).values)
        + (config.args ?? [])
    return values.flatMap(secretReferences(in:))
}

func relativeToCurrentDirectory(_ path: String) -> String {
    let current = FileManager.default.currentDirectoryPath + "/"
    return path.hasPrefix(current) ? String(path.dropFirst(current.count)) : path
}
