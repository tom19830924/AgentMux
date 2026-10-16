import Foundation

func listCommand() throws -> Int32 {
    let paths = try ProjectPaths.require()
    let config = try GatewayStore.load(paths.configFile)
    let secrets = try SecretStore.load(paths.secretsFile)

    var lines = [ansi.dim(relativeToCurrentDirectory(paths.configFile)), ""]

    guard !config.gateways.isEmpty else {
        Terminal.write("\(ansi.dim("還沒有設定任何 gateway，執行")) am add \(ansi.dim("新增一個"))\n")
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
                status = ansi.dim("不需金鑰")
            } else if missing.isEmpty {
                status = ansi.green("金鑰已設定 (\(referenced.sorted().joined(separator: ", ")))")
            } else {
                status = ansi.red("缺少金鑰：\(missing.joined(separator: ", "))")
            }

            let model = agentConfig.model.map { " \(ansi.dim($0))" } ?? ""
            lines.append("  \(agent.id.padding(toLength: 7, withPad: " ", startingAt: 0))\(model)  \(status)")
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
