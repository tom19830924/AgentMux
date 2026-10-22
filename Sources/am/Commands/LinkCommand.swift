import Foundation

// MARK: - The decision

/// What is sitting where the link belongs.
enum LinkedPathState: Equatable {
    case missing
    /// A link `am` could have made itself, pointing at this agent's directory.
    case ourLink
    case otherLink(String)
    case directory
    case file
}

enum LinkPlan: Equatable {
    case create
    /// Something of the user's is in the way; moving it is their call.
    case askBeforeRenaming
    case refuse
}

/// Decided before anything is touched, so the awkward cases can be tested
/// without a filesystem to arrange.
func linkPlan(for state: LinkedPathState) -> LinkPlan {
    switch state {
    case .missing, .ourLink: .create
    case .directory: .askBeforeRenaming
    case .otherLink, .file: .refuse
    }
}

/// Where the link points, relative to the project root so that moving the
/// whole project does not break it.
func relativeLinkTarget(for agent: Agent) -> String {
    "\(ProjectPaths.directoryName)/\(agent.configDirectoryName)"
}

private func state(of path: String, expecting target: String) -> LinkedPathState {
    let manager = FileManager.default
    guard let attributes = try? manager.attributesOfItem(atPath: path) else { return .missing }
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        let destination = (try? manager.destinationOfSymbolicLink(atPath: path)) ?? ""
        return destination == target ? .ourLink : .otherLink(destination)
    }
    var isDirectory: ObjCBool = false
    _ = manager.fileExists(atPath: path, isDirectory: &isDirectory)
    return isDirectory.boolValue ? .directory : .file
}

// MARK: - Linking

enum LinkPreparation: Equatable {
    case ready
    case renameFirst
}

/// Settles everything that needs the user before anything is written, so an
/// abandoned run leaves the project as it was.
func prepareLink(for agent: Agent, paths: ProjectPaths, prompter: Prompter) throws
    -> LinkPreparation
{
    let link = paths.projectLink(for: agent)

    switch linkPlan(for: state(of: link, expecting: relativeLinkTarget(for: agent))) {
    case .create:
        return .ready

    case .refuse:
        throw AgentMuxError(
            "\(relativeToCurrentDirectory(link)) is already something else",
            hint: "Move it aside yourself, then run this again"
        )

    case .askBeforeRenaming:
        let backup = paths.linkBackup(for: agent)
        guard Terminal.isInteractive || !(prompter is TerminalPrompter) else {
            throw AgentMuxError(
                "\(relativeToCurrentDirectory(link)) already exists",
                hint: "Run this in a terminal, where it can ask before moving anything"
            )
        }
        guard !FileManager.default.fileExists(atPath: backup) else {
            throw AgentMuxError(
                "\(relativeToCurrentDirectory(backup)) is already there",
                hint: "Deal with that one first; am will not stack backups on top of each other"
            )
        }
        // The copy below would land on top of this one, and .agentmux/ is the
        // directory this command must never rewrite. Two directories holding
        // configuration is a question only the user can answer, so it is asked
        // here rather than settled by whichever order the writes happen in.
        let backing = paths.linkedDirectory(for: agent)
        guard !FileManager.default.fileExists(atPath: backing) else {
            throw AgentMuxError(
                "\(relativeToCurrentDirectory(backing)) is already there",
                hint: "Both it and \(relativeToCurrentDirectory(link)) hold configuration. "
                    + "Keep whichever you want and move the other aside, then run this again"
            )
        }
        let answer = try prompter.select(
            "\(agent.configDirectoryName)/ already exists here",
            [
                Choice(
                    value: "rename",
                    label: "Move it into .agentmux/ and keep a copy as "
                        + "\(agent.configDirectoryName)_bak"
                ),
                Choice(value: "cancel", label: "Cancel"),
            ]
        )
        if answer == "cancel" { throw CancelledError() }
        return .renameFirst
    }
}

/// Moves an agent's own configuration directory into `.agentmux/` and links it
/// back, so that moving that one directory carries the project's setup.
///
/// Nothing is generated here. Whatever the agent reads from that directory is
/// the user's to put there, which is why an existing directory is copied
/// across rather than set aside: the contents are the configuration.
func writeLink(for agent: Agent, paths: ProjectPaths, preparation: LinkPreparation) throws -> Int32 {
    let manager = FileManager.default
    let link = paths.projectLink(for: agent)
    let backing = paths.linkedDirectory(for: agent)
    let backup = paths.linkBackup(for: agent)

    // First write of the whole flow: every question was answered above.
    if preparation == .renameFirst {
        try manager.moveItem(atPath: link, toPath: backup)
        // Kept as well as copied: the copy is what the agent reads from now
        // on, and the original stays untouched in case this was a mistake.
        try manager.copyItem(atPath: backup, toPath: backing)
        Terminal.write(
            "\(ansi.dim("moved")) \(relativeToCurrentDirectory(link))"
                + " → \(relativeToCurrentDirectory(backing))"
                + " \(ansi.dim("(kept a copy as \(relativeToCurrentDirectory(backup)))"))\n"
        )
    } else {
        try manager.createDirectory(atPath: backing, withIntermediateDirectories: true)
    }

    if !manager.fileExists(atPath: link) {
        try manager.createSymbolicLink(
            atPath: link, withDestinationPath: relativeLinkTarget(for: agent)
        )
    }

    Terminal.write(
        "\(ansi.green("Linked")) \(relativeToCurrentDirectory(link))"
            + " → \(relativeLinkTarget(for: agent))\n"
    )
    for warning in linkWarnings(for: agent, paths: paths) {
        Terminal.write("\(ansi.dim(warning))\n")
    }
    return 0
}

/// Removes an agent's link, and only one `am` could have made itself.
///
/// Says which of those happened rather than reporting success either way: the
/// whole point of the check is that it sometimes removes nothing, and a line
/// reading "Unlinked" over an untouched directory would hide exactly the case
/// it exists to protect.
///
/// Having nothing to remove is not a failure — `--unlink` asks for the link to
/// be gone, and it is — so the status stays 0 and a script can rely on it.
func unlinkDirectory(for agent: Agent, paths: ProjectPaths) throws -> Int32 {
    let link = paths.projectLink(for: agent)
    let target = relativeLinkTarget(for: agent)
    let shown = relativeToCurrentDirectory(link)

    switch state(of: link, expecting: target) {
    case .ourLink:
        try FileManager.default.removeItem(atPath: link)
        Terminal.write("\(ansi.green("Unlinked")) \(shown) \(ansi.dim("(\(target) is untouched)"))\n")
    case .missing:
        Terminal.write(ansi.dim("Nothing to unlink: there is no \(shown)\n"))
    case .directory, .file:
        Terminal.write(ansi.dim("Left alone: \(shown) is not a link am made\n"))
    case let .otherLink(destination):
        Terminal.write(ansi.dim("Left alone: \(shown) points at \(destination), not \(target)\n"))
    }
    return 0
}

/// Worth saying once the link is in place, without stopping anything.
func linkWarnings(for agent: Agent, paths: ProjectPaths) -> [String] {
    let link = paths.projectLink(for: agent)
    guard !pathIsGitIgnored(link, in: paths.root) else { return [] }
    return [
        "\(agent.configDirectoryName) is not git-ignored here, so the link would be "
            + "committed while the directory it points at usually is not."
    ]
}

func pathIsGitIgnored(_ path: String, in root: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", root, "check-ignore", "-q", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return true }
    process.waitUntilExit()

    // check-ignore answers 0 for ignored and 1 for not; anything else means it
    // could not answer at all, usually because there is no repository here —
    // and with no repository there is no commit to warn about.
    switch process.terminationStatus {
    case 0: return true
    case 1: return false
    default: return true
    }
}
