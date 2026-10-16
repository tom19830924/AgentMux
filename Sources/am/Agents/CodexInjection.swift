import Foundation

/// Codex layers configuration from highest to lowest:
///
///   1. CLI flags / `-c key=value`        <- we use this one
///   2. project .codex/config.toml        (only when the project is trusted)
///   3. --profile
///   4. ~/.codex/config.toml
///   5. managed / system / built-in defaults
///
/// `-c` sits at the top and needs no file, so neither the user's
/// ~/.codex/config.toml nor any project .codex/config.toml is touched and a
/// bare `codex` keeps behaving exactly as before.
///
/// Secrets never go through `-c`: command lines are visible in `ps aux`. The
/// provider's `env_key` names an environment variable instead, and the value
/// travels in the launched process's environment.
func buildCodexInjection(_ config: AgentConfig, _ context: InjectionContext) throws -> Injection {
    if let settings = config.settings, !settings.isEmpty {
        throw AgentMuxError(
            "Codex 不支援 `settings` 欄位",
            hint: "請改用 `args` 搭配 -c 覆寫，金鑰放在 `env` 並以 env_key 指向它"
        )
    }

    return Injection(
        args: try (config.args ?? []).map { try context.resolver.resolve($0) },
        env: try context.resolver.resolve(config.env)
    )
}
