import Foundation

/// Creates `.agentmux/` and then walks straight into the add wizard, so the
/// command leaves behind a gateway that works rather than a template to fill in.
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

    try FileManager.default.createDirectory(
        atPath: paths.directory, withIntermediateDirectories: true
    )
    try GatewayStore.save(.empty(), to: paths.configFile)
    try SecretStore.save([:], to: paths.secretsFile)

    Terminal.write(
        "\(ansi.green("已建立")) \(relativeToCurrentDirectory(paths.directory))/"
            + "\(ansi.dim("（gateways.json、secrets.json 0600）"))\n\n"
    )

    do {
        return try addCommand(paths: paths, prompter: prompter)
    } catch {
        // A cancelled wizard must not leave an empty config behind.
        try? FileManager.default.removeItem(atPath: paths.directory)
        Terminal.write(ansi.dim("已取消，未留下任何設定檔") + "\n")
        throw error
    }
}
