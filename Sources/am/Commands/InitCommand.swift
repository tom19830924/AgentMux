import Foundation

/// Walks straight into the add wizard, so the command leaves behind a gateway
/// that works rather than a template to fill in. `.agentmux/` appears only when
/// the wizard reaches the end: an abandoned run leaves nothing behind.
///
/// Everything it writes stays inside `.agentmux/`: nothing is read from
/// .claude/settings.json or .codex/config.toml, and no .gitignore is touched —
/// ignoring the directory is left to the project.
func initCommand(prompter: Prompter? = nil) throws -> Int32 {
    let root = FileManager.default.currentDirectoryPath
    let paths = ProjectPaths(root: root)

    if FileManager.default.fileExists(atPath: paths.configFile) {
        throw AgentMuxError(
            "\(relativeToCurrentDirectory(paths.configFile)) 已經存在",
            hint: "要新增 gateway 請用 `am add`"
        )
    }

    if prompter == nil, !Terminal.isInteractive {
        throw AgentMuxError("am init 需要互動式終端機", hint: "請直接在終端機裡執行")
    }

    // The wizard creates the directory only once it has every answer it needs.
    // Nothing is written up front, so an abandoned run leaves no half-made
    // project to trip over the "already exists" check on the next attempt —
    // and that holds for Ctrl-C too, which no clean-up here would survive.
    return try addCommand(paths: paths, prompter: prompter, creatingProject: true)
}
