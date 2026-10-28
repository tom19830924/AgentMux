import Foundation

/// Writes this project's gateway where Claude Code's editor extension reads
/// it: `.claude/settings.local.json`.
///
/// `am claude` needs none of this — it passes the gateway to the agent as it
/// starts it, and writes nothing. The extension never goes through `am`, so
/// the only way it can know about a gateway is to find it in the file Claude
/// Code reads for personal, per-project settings. That file is git-ignored,
/// which is also where a base URL and a key's name belong.
///
/// Two keys, and only ever those two:
///
///   - `apiKeyHelper`, as `am secret get <name>` — relative, so the file keeps
///     working if the project moves, and the key itself stays in secrets.json
///   - `env.ANTHROPIC_BASE_URL`
///
/// Everything else in the file is Claude Code's or the user's — approvals,
/// permission rules, their own variables, their own indentation — and comes
/// through untouched. See `JSONTextEdit`.
func extensionCommand(paths suppliedPaths: ProjectPaths? = nil, prompter: Prompter? = nil) throws
    -> Int32
{
    let paths = try suppliedPaths ?? ProjectPaths.require()
    if prompter == nil, !Terminal.isInteractive {
        throw AgentMuxError(
            "This command needs an interactive terminal",
            hint: "Run it in a terminal, or edit \(relativeToCurrentDirectory(paths.claudeSettingsFile)) by hand"
        )
    }
    let ui = prompter ?? TerminalPrompter()

    let config = try GatewayStore.load(paths.configFile)
    let candidates = config.gateways(supporting: .claude)
    guard !candidates.isEmpty else {
        throw AgentMuxError(
            "No gateway in \(relativeToCurrentDirectory(paths.configFile)) supports claude",
            hint: "Run `am add` to add claude to one of them"
        )
    }

    // Read before asking: refusing a file we cannot edit is worth doing before
    // the questions, not after them.
    let existing = try readSettings(at: paths.claudeSettingsFile)
    ui.intro("Write a gateway into \(relativeToCurrentDirectory(paths.claudeSettingsFile))")
    showCurrent(existing?.parsed, ui: ui)

    let gateway = try chooseGateway(candidates, current: existing?.parsed, paths: paths, ui: ui)

    // A gateway that names no secret has no key to fetch — "use Claude Code's
    // own login" is the whole point of it. Asking anyway would offer a wrong
    // answer and then write it down.
    let claude = gateway.agents["claude"]!
    let baseURL = claude.settings?["ANTHROPIC_BASE_URL"] ?? ""

    // An empty base URL is how am spells "Claude Code's own login" — it is
    // what the menu offers as the hint, and the one gateway that signs in
    // rather than presenting a key.
    let isOwnLogin = baseURL.isEmpty
    let key = secretReferencesIn(claude).isEmpty
        ? nil
        : try chooseKey(for: gateway, config: config, paths: paths, ui: ui)

    var text = existing?.text ?? "{\n}\n"
    guard let withURL = JSONTextEdit.setString(
        baseURL, at: ["env", "ANTHROPIC_BASE_URL"], in: text
    ) else { throw cannotEdit(paths) }
    text = withURL

    // What the helper was, when this run is about to stop it fetching a key.
    // Printed where the change happens so the old value stays recoverable.
    var cleared: String?

    if let key {
        guard let withHelper = JSONTextEdit.setString(
            "am secret get \(key)", at: ["apiKeyHelper"], in: text
        ) else { throw cannotEdit(paths) }
        text = withHelper
    } else if isOwnLogin, let stale = existing?.parsed["apiKeyHelper"] as? String, !stale.isEmpty {
        // Claude Code's own login, with a helper left from some other gateway.
        // Left alone it would quietly keep winning — Claude Code's own advice
        // for this state is to unset the setting. An empty command is how it
        // reads "unset" (every site that reaches a helper first tests the
        // value for truth), so this is the same replacement the base URL
        // gets, not the deletion this command never does.
        guard let blanked = JSONTextEdit.setString("", at: ["apiKeyHelper"], in: text)
        else { throw cannotEdit(paths) }
        text = blanked
        cleared = stale
    }

    try writeVerifiedSettings(text, over: existing?.parsed, to: paths.claudeSettingsFile)

    ui.outro("\(ansi.green("Ready")) \(gateway.displayName)"
        + (key.map { " / \($0)" } ?? "")
        + ansi.dim("   the editor picks this up next time it starts"))

    if let cleared {
        ui.note(ansi.dim(
            "Emptied apiKeyHelper so this gateway uses Claude Code's own login.\n"
                + "It was: \(cleared)\n"
        ))
    }
    return 0
}

// MARK: Reading what is already there

private struct Settings {
    let text: String
    let parsed: [String: Any]
}

/// Loads the file, or nothing when it does not exist yet. A file that cannot
/// be edited safely stops the command rather than being overwritten: it holds
/// approvals and permission rules that took the user real decisions to make.
private func readSettings(at file: String) throws -> Settings? {
    guard let data = FileManager.default.contents(atPath: file) else { return nil }
    let text = String(decoding: data, as: UTF8.self)

    guard let object = try? JSONSerialization.jsonObject(with: data),
          let parsed = object as? [String: Any]
    else {
        throw AgentMuxError(
            "\(relativeToCurrentDirectory(file)) is not a JSON object",
            hint: "Fix it by hand first; am will not overwrite a file it cannot read"
        )
    }
    if let env = parsed["env"], !(env is [String: Any]) {
        throw AgentMuxError(
            "\(relativeToCurrentDirectory(file)) has an \"env\" that is not an object",
            hint: "Fix it by hand first; am will not overwrite a file it cannot read"
        )
    }
    return Settings(text: text, parsed: parsed)
}

private func showCurrent(_ parsed: [String: Any]?, ui: Prompter) {
    guard let parsed else { return }
    let helper = parsed["apiKeyHelper"] as? String
    let url = (parsed["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
    guard helper != nil || url != nil else { return }

    var lines = [ansi.dim("Currently:")]
    if let url { lines.append("  ANTHROPIC_BASE_URL  \(url.isEmpty ? ansi.dim("(empty)") : url)") }
    if let helper { lines.append("  apiKeyHelper        \(helper)") }
    ui.note(lines.joined(separator: "\n") + "\n")
}

// MARK: Asking

private func chooseGateway(
    _ candidates: [Gateway], current: [String: Any]?, paths: ProjectPaths, ui: Prompter
) throws -> Gateway {
    let currentURL = (current?["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
    let matching = candidates.first {
        $0.agents["claude"]?.settings?["ANTHROPIC_BASE_URL"] == currentURL
    }
    let initial = matching?.id ?? LaunchState.load(paths.stateFile).lastGateway?["claude"]

    let chosen = try ui.select(
        "Which gateway?",
        candidates.map { gateway in
            let url = gateway.agents["claude"]?.settings?["ANTHROPIC_BASE_URL"] ?? ""
            return Choice(
                value: gateway.id, label: gateway.displayName,
                hint: url.isEmpty ? "Claude Code's own login" : url
            )
        },
        initial: initial
    )
    return candidates.first { $0.id == chosen }!
}

/// Which key the helper should fetch. Asked separately from the gateway
/// because one endpoint is often reached with more than one key, and the
/// gateway's own reference is only the obvious default.
private func chooseKey(
    for gateway: Gateway, config: GatewayFile, paths: ProjectPaths, ui: Prompter
) throws -> String? {
    let stored = try SecretStore.load(paths.secretsFile)
    let referenced = config.gateways.flatMap { $0.agents.values.flatMap(secretReferencesIn) }
    let known = Set(stored.keys).union(referenced).sorted()
    guard !known.isEmpty else { return nil }

    let own = gateway.agents["claude"].map(secretReferencesIn)?.first
    let chosen = try ui.select(
        "Which key?",
        known.map { name in
            Choice(
                value: name, label: name,
                hint: stored[name] != nil ? nil : "Referenced, but has no value yet"
            )
        },
        initial: own ?? known.first
    )
    return chosen
}

// MARK: Writing

private func cannotEdit(_ paths: ProjectPaths) -> AgentMuxError {
    AgentMuxError(
        "Could not place the settings in \(relativeToCurrentDirectory(paths.claudeSettingsFile))",
        hint: "Nothing was written. Add \"apiKeyHelper\" and \"env\" by hand, "
            + "then run this again to fill them in"
    )
}

/// Writes the edited text, but only once it has proved that the edit changed
/// nothing it was not asked to change.
///
/// Editing JSON as text is how the file keeps its layout, and it is also how a
/// subtle mistake could drop a member or break a nesting. Comparing what the
/// two documents say — apart from the two keys that are ours — turns that
/// class of mistake into a refusal instead of a damaged file.
func writeVerifiedSettings(_ text: String, over before: [String: Any]?, to file: String) throws {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
          let parsed = object as? [String: Any]
    else { throw verificationFailed(file) }

    if let before, !sameApartFromOurs(before, parsed) {
        throw verificationFailed(file)
    }

    try FileManager.default.createDirectory(
        atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
}

private func verificationFailed(_ file: String) -> AgentMuxError {
    AgentMuxError(
        "The edit to \(relativeToCurrentDirectory(file)) would have changed something else",
        hint: "Nothing was written. This is a bug in am; please report the file's shape"
    )
}

/// Both documents with `apiKeyHelper` and `env.ANTHROPIC_BASE_URL` removed.
private func sameApartFromOurs(_ before: [String: Any], _ after: [String: Any]) -> Bool {
    func stripped(_ object: [String: Any]) -> NSDictionary {
        var copy = object
        copy["apiKeyHelper"] = nil
        if var env = copy["env"] as? [String: Any] {
            env["ANTHROPIC_BASE_URL"] = nil
            copy["env"] = env.isEmpty ? nil : env
        }
        return copy as NSDictionary
    }
    return stripped(before) == stripped(after)
}
