import Foundation

/// Claude Code reads settings from several layers. From highest to lowest:
///
///   1. managed settings
///   2. `claude --settings <file-or-json>`   <- we use this one
///   3. .claude/settings.local.json
///   4. .claude/settings.json
///   5. ~/.claude/settings.json
///
/// Environment variables are deliberately NOT used: a settings file's `env`
/// block replaces the value inherited from the shell, so a project's own
/// .claude/settings.json would silently win over anything we exported and the
/// user would pick one gateway but connect to another. `--settings` sits above
/// that file, and because the flag loads *additional* settings rather than
/// replacing them, the project's hooks and permissions keep working.
///
/// The settings are passed inline as JSON, which is visible in `ps`, so the
/// token never goes in it. Instead `ANTHROPIC_AUTH_TOKEN` is set to the empty
/// string — which cancels whatever the project's file sets — and `apiKeyHelper`
/// names a command Claude Code runs when it actually needs the key. The key
/// therefore never lands on disk and never reaches a command line.
///
/// What a gateway amounts to for Claude Code: the `env` block it should see,
/// and the command that fetches the key when the token is a whole reference.
struct ClaudeSettings: Equatable {
    var env: [String: String] = [:]
    var apiKeyHelper: String?
    /// The command Claude Code runs to draw the status line.
    var statusLine: String?

    var isEmpty: Bool { env.isEmpty && apiKeyHelper == nil && statusLine == nil }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["env": env]
        if let apiKeyHelper { object["apiKeyHelper"] = apiKeyHelper }
        if let statusLine {
            object["statusLine"] = ["type": "command", "command": statusLine]
        }
        return object
    }
}

func claudeSettings(_ config: AgentConfig, _ context: InjectionContext) throws -> ClaudeSettings {
    var settings = ClaudeSettings()

    for (key, raw) in config.settings ?? [:] {
        if key == "ANTHROPIC_AUTH_TOKEN", let name = wholeSecretReference(raw) {
            settings.apiKeyHelper = try context.secretHelperCommand(name)
            settings.env[key] = ""
        } else {
            settings.env[key] = try context.resolver.resolve(raw)
        }
    }

    settings.statusLine = context.statusLine
    return settings
}

func buildClaudeInjection(_ config: AgentConfig, _ context: InjectionContext) throws -> Injection {
    var injection = Injection()
    injection.env = try context.resolver.resolve(config.env)

    let settings = try claudeSettings(config, context)
    var args = try (config.args ?? []).map { try context.resolver.resolve($0) }
    if !settings.isEmpty {
        let data = try JSONSerialization.data(
            withJSONObject: settings.jsonObject(), options: [.sortedKeys, .withoutEscapingSlashes]
        )
        args.insert(contentsOf: ["--settings", String(decoding: data, as: UTF8.self)], at: 0)
    }
    injection.args = args
    return injection
}

/// The name in a value that is exactly one secret reference, e.g. `${secret:key}`.
func wholeSecretReference(_ raw: String) -> String? {
    guard raw.hasPrefix("${secret:"), raw.hasSuffix("}") else { return nil }
    let name = raw.dropFirst("${secret:".count).dropLast()
    guard !name.isEmpty, !name.contains("{"), !name.contains("}") else { return nil }
    return String(name)
}
