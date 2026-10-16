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
func buildClaudeInjection(_ config: AgentConfig, _ context: InjectionContext) throws -> Injection {
    var injection = Injection()
    injection.env = try context.resolver.resolve(config.env)

    var settingsEnv: [String: String] = [:]
    var helperFor: String?

    for (key, raw) in config.settings ?? [:] {
        if key == "ANTHROPIC_AUTH_TOKEN", let name = wholeSecretReference(raw) {
            helperFor = name
            settingsEnv[key] = ""
        } else {
            settingsEnv[key] = try context.resolver.resolve(raw)
        }
    }

    var payload: [String: Any] = ["env": settingsEnv]
    if let helperFor {
        payload["apiKeyHelper"] = try context.secretHelperCommand(helperFor)
    }

    var args = try (config.args ?? []).map { try context.resolver.resolve($0) }
    if !settingsEnv.isEmpty || helperFor != nil {
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
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
