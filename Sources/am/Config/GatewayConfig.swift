import Foundation

/// Per-agent configuration inside a gateway.
///
/// The fields differ by agent because the two CLIs take their configuration
/// through different channels (see Sources/am/Agents/):
///   - `settings` is Claude Code only; it becomes the `env` block of the JSON
///     handed to `claude --settings`.
///   - `args` are extra command line arguments, used by Codex for `-c` overrides.
///   - `env` are environment variables for the launched process. Secrets belong
///     here rather than in `args`, which are visible in `ps aux`.
struct AgentConfig: Codable, Equatable {
    var settings: [String: String]?
    var args: [String]?
    var env: [String: String]?

    init(
        settings: [String: String]? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil
    ) {
        self.settings = settings
        self.args = args
        self.env = env
    }
}

struct Gateway: Codable, Equatable {
    var id: String
    /// Optional: when absent the id is shown in the menu. `am add` asks for one
    /// name and uses it for both, so it normally stays absent.
    var label: String?
    var agents: [String: AgentConfig]

    var displayName: String { label ?? id }
}

struct GatewayFile: Codable, Equatable {
    var version: Int
    var gateways: [Gateway]

    static let currentVersion = 1

    static func empty() -> GatewayFile {
        GatewayFile(version: currentVersion, gateways: [])
    }

    func gateway(id: String) -> Gateway? {
        gateways.first { $0.id == id }
    }

    /// Gateways that declare support for the given agent.
    func gateways(supporting agent: Agent) -> [Gateway] {
        gateways.filter { $0.agents[agent.id] != nil }
    }
}

enum GatewayStore {
    static func load(_ file: String) throws -> GatewayFile {
        guard let data = FileManager.default.contents(atPath: file) else {
            throw AgentMuxError(
                "Cannot find \(file)",
                hint: "Run `am init` in the project root to create it"
            )
        }

        let config: GatewayFile
        do {
            config = try JSONDecoder().decode(GatewayFile.self, from: data)
        } catch {
            throw AgentMuxError(
                "\(file) is not valid",
                hint: readableDecodingError(error)
            )
        }

        guard config.version == GatewayFile.currentVersion else {
            throw AgentMuxError("\(file) must have version \(GatewayFile.currentVersion)")
        }

        var seen = Set<String>()
        for gateway in config.gateways {
            guard seen.insert(gateway.id).inserted else {
                throw AgentMuxError("\(file) has two gateways with the id \"\(gateway.id)\"")
            }
        }
        return config
    }

    static func save(_ config: GatewayFile, to file: String) throws {
        let encoder = JSONEncoder()
        // Stable key order keeps diffs clean; unescaped slashes keep URLs readable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    private static func readableDecodingError(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case let .keyNotFound(key, context):
            return "Missing field \"\(key.stringValue)\" (at \(path(context)))"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(context.debugDescription) (at \(path(context)))"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return "\(error)"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map(\.stringValue)
        return parts.isEmpty ? "the top level" : parts.joined(separator: ".")
    }
}
