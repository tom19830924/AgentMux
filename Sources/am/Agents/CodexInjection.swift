/// Codex layers configuration from highest to lowest:
///
///   1. CLI flags / `-c key=value`        <- we use this one
///   2. --profile
///   3. ~/.codex/config.toml
///   4. managed / system / built-in defaults
///
/// A project's own `.codex/config.toml` is deliberately absent from that list.
/// Measured against codex-cli 0.163.0, with the project marked trusted, it is
/// ignored for `model` and `model_providers` alike: only the home file and
/// `-c` decide them. So there is no project-level layer for a gateway to live
/// in, which is why an editor extension cannot be given one the way Claude
/// Code's is — the layer the Claude side uses has no counterpart here.
///
/// `-c` sits at the top and needs no file, so the user's ~/.codex/config.toml
/// is never touched and a bare `codex` keeps behaving exactly as before.
///
/// Secrets never go through `-c`: command lines are visible in `ps aux`. The
/// provider's `env_key` names an environment variable instead, and the value
/// travels in the launched process's environment.
func buildCodexInjection(_ config: AgentConfig, _ context: InjectionContext) throws -> Injection {
    if let settings = config.settings, !settings.isEmpty {
        throw AgentMuxError(
            "Codex has no `settings` field",
            hint: "Use `args` with -c overrides instead, and put the key in `env` with env_key pointing at it"
        )
    }

    return Injection(
        args: try (config.args ?? []).map { try context.resolver.resolve($0) },
        env: try context.resolver.resolve(config.env)
    )
}
