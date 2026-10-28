import Foundation

/// What a gateway contributes to a launch.
struct Injection: Equatable {
    var args: [String] = []
    var env: [String: String] = [:]
}

struct InjectionContext {
    let resolver: SecretResolver
    /// The command an agent should run to draw its status line, or nil when
    /// this project has not asked for one. Built by the caller, which is the
    /// only place that knows which gateway was chosen.
    let statusLine: String?
    /// Builds a shell command that prints the named secret, for an agent that
    /// can fetch its key on demand rather than being handed it up front.
    let secretHelperCommand: (String) throws -> String
}

enum Agent: String, CaseIterable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        }
    }

    /// Gateway name used for "use the CLI's own login"; the wizard never asks for it.
    var officialId: String {
        switch self {
        case .claude: "anthropic"
        case .codex: "openai"
        }
    }

    /// One line shown by `am --help` explaining how this agent receives the gateway.
    var injectionSummary: String {
        switch self {
        case .claude: "--settings + apiKeyHelper"
        case .codex: "-c overrides"
        }
    }

    /// Executable to run. The environment override exists so tests can point an
    /// agent at a stub without touching the rest of the launch path.
    var command: String {
        ProcessInfo.processInfo.environment["AGENTMUX_\(rawValue.uppercased())_COMMAND"] ?? rawValue
    }

    func build(_ config: AgentConfig, _ context: InjectionContext) throws -> Injection {
        switch self {
        case .claude: try buildClaudeInjection(config, context)
        case .codex: try buildCodexInjection(config, context)
        }
    }

    static func named(_ id: String) throws -> Agent {
        guard let agent = Agent(rawValue: id) else {
            throw AgentMuxError(
                "Unknown agent \"\(id)\"",
                hint: "Supported agents: \(allCases.map(\.id).joined(separator: ", "))"
            )
        }
        return agent
    }

    static func isAgent(_ id: String) -> Bool { Agent(rawValue: id) != nil }
}
