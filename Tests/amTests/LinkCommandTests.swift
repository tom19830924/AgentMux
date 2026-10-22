import Foundation
import Testing

@testable import am

/// `--link` does one thing, and does it the same way for every agent: move
/// that agent's own configuration directory into `.agentmux/` and link it
/// back, so moving that one directory carries the project's whole setup.
///
/// Every case here runs for both agents from the same assertions. The point is
/// not coverage but shape: a behaviour that differs by agent cannot pass.
@Suite("am <agent> --link", .serialized)
struct LinkCommandTests {
    private func project() throws -> ProjectPaths {
        try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: [
                "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": "https://alpha.example.com"]),
                "codex": AgentConfig(args: []),
            ]),
        ]))
    }

    private func link(_ agent: Agent, _ paths: ProjectPaths) -> String {
        paths.projectLink(for: agent)
    }

    private func backing(_ agent: Agent, _ paths: ProjectPaths) -> String {
        paths.linkedDirectory(for: agent)
    }

    private func backup(_ agent: Agent, _ paths: ProjectPaths) -> String {
        paths.linkBackup(for: agent)
    }

    // MARK: Linking

    @Test("With nothing there it makes the directory and links it", arguments: Agent.allCases)
    func linksFromNothing(agent: Agent) throws {
        let paths = try project()
        let run = try runAm(["--link", agent.id], in: paths.root)
        #expect(run.status == 0)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: backing(agent, paths), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link(agent, paths))
        #expect(destination == ".agentmux/\(agent.configDirectoryName)")
    }

    /// Relative, so moving the project does not break it.
    @Test("The link carries no absolute path", arguments: Agent.allCases)
    func theLinkIsRelative(agent: Agent) throws {
        let paths = try project()
        _ = try runAm(["--link", agent.id], in: paths.root)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link(agent, paths))
        #expect(!destination.hasPrefix("/"))
    }

    /// The contents are the whole point: nothing is generated, so leaving them
    /// behind would link an empty directory and lose the configuration.
    @Test("An existing directory is carried over, and kept as a backup", arguments: Agent.allCases)
    func carriesTheConfigurationOver(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createDirectory(
            atPath: link(agent, paths), withIntermediateDirectories: true
        )
        let marker = (link(agent, paths) as NSString).appendingPathComponent("mine.txt")
        try "kept".write(toFile: marker, atomically: true, encoding: .utf8)

        let session = try TerminalSession(["--link", agent.id], in: paths.root)
        try session.wait(for: "already exists")
        session.send("\r")
        try session.wait(for: "Linked")
        #expect(try session.waitUntilExit() == 0)

        let moved = (backing(agent, paths) as NSString).appendingPathComponent("mine.txt")
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "kept")

        let kept = (backup(agent, paths) as NSString).appendingPathComponent("mine.txt")
        #expect(FileManager.default.fileExists(atPath: kept))
    }

    @Test("Reading through the link reaches the same file", arguments: Agent.allCases)
    func readableThroughTheLink(agent: Agent) throws {
        let paths = try project()
        _ = try runAm(["--link", agent.id], in: paths.root)

        let inside = (backing(agent, paths) as NSString).appendingPathComponent("config")
        try "value".write(toFile: inside, atomically: true, encoding: .utf8)

        let throughLink = (link(agent, paths) as NSString).appendingPathComponent("config")
        #expect(try String(contentsOfFile: throughLink, encoding: .utf8) == "value")
    }

    @Test("Running it again over its own link succeeds", arguments: Agent.allCases)
    func runningTwiceIsFine(agent: Agent) throws {
        let paths = try project()
        _ = try runAm(["--link", agent.id], in: paths.root)
        #expect(try runAm(["--link", agent.id], in: paths.root).status == 0)
    }

    // MARK: Refusing

    @Test("Without a terminal it will not move a directory", arguments: Agent.allCases)
    func refusesToRenameUnattended(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createDirectory(
            atPath: link(agent, paths), withIntermediateDirectories: true
        )
        let run = try runAm(["--link", agent.id], in: paths.root)
        #expect(run.status != 0)
        #expect(!FileManager.default.fileExists(atPath: backup(agent, paths)))
    }

    @Test("A link pointing somewhere else is refused, not replaced", arguments: Agent.allCases)
    func refusesAForeignLink(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createSymbolicLink(
            atPath: link(agent, paths), withDestinationPath: "elsewhere"
        )
        let run = try runAm(["--link", agent.id], in: paths.root)
        #expect(run.status != 0)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link(agent, paths))
        #expect(destination == "elsewhere")
    }

    @Test("A backup already set aside stops it", arguments: Agent.allCases)
    func refusesToStackBackups(agent: Agent) throws {
        let paths = try project()
        for path in [link(agent, paths), backup(agent, paths)] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let session = try TerminalSession(["--link", agent.id], in: paths.root)
        try session.wait(for: "already")
        #expect(try session.waitUntilExit() != 0)
    }

    /// Both directories hold configuration, and only one of them can be the
    /// one the agent reads. Choosing for the user would silently discard the
    /// other, so it is refused — and refused before the rename, because a
    /// half-done move leaves the agent with no configuration at all.
    @Test("A directory already inside .agentmux/ stops it", arguments: Agent.allCases)
    func refusesToOverwriteTheBackingDirectory(agent: Agent) throws {
        let paths = try project()
        for path in [link(agent, paths), backing(agent, paths)] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let mine = (backing(agent, paths) as NSString).appendingPathComponent("mine.txt")
        try "kept".write(toFile: mine, atomically: true, encoding: .utf8)

        let session = try TerminalSession(["--link", agent.id], in: paths.root)
        try session.wait(for: "already there")
        #expect(try session.waitUntilExit() != 0)

        // Nothing of the user's moved, in either direction.
        #expect(try String(contentsOfFile: mine, encoding: .utf8) == "kept")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: link(agent, paths), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: backup(agent, paths)))
    }

    /// `--link` chooses no gateway, so naming one is a misunderstanding worth
    /// saying rather than ignoring.
    @Test("A gateway with --link is refused", arguments: Agent.allCases)
    func linkTakesNoGateway(agent: Agent) throws {
        let paths = try project()
        let run = try runAm(["--link", "-g", "alpha", agent.id], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("no gateway"))
    }

    // MARK: Unlinking

    @Test("--unlink removes the link and keeps the directory", arguments: Agent.allCases)
    func unlinks(agent: Agent) throws {
        let paths = try project()
        _ = try runAm(["--link", agent.id], in: paths.root)

        let run = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("Unlinked"))
        #expect(!FileManager.default.fileExists(atPath: link(agent, paths)))
        #expect(FileManager.default.fileExists(atPath: backing(agent, paths)))
    }

    /// It reports success either way unless it says which happened, and the
    /// case worth seeing is the one where it deliberately removed nothing.
    @Test("--unlink says so when it removed nothing", arguments: Agent.allCases)
    func unlinkSaysWhenItRemovedNothing(agent: Agent) throws {
        let paths = try project()

        // Nothing there at all.
        let absent = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(absent.status == 0)
        #expect(!absent.stdout.contains("Unlinked"))
        #expect(absent.stdout.contains("Nothing to unlink"))

        // A real directory of the user's.
        try FileManager.default.createDirectory(
            atPath: link(agent, paths), withIntermediateDirectories: true
        )
        let real = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(real.status == 0)
        #expect(!real.stdout.contains("Unlinked"))
        #expect(real.stdout.contains("Left alone"))
        #expect(FileManager.default.fileExists(atPath: link(agent, paths)))
    }

    @Test("--unlink names where a foreign link points", arguments: Agent.allCases)
    func unlinkNamesAForeignTarget(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createSymbolicLink(
            atPath: link(agent, paths), withDestinationPath: "somewhere-else"
        )
        let run = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(!run.stdout.contains("Unlinked"))
        #expect(run.stdout.contains("somewhere-else"))
    }

    /// `--unlink` deletes something, so what it will not delete is worth
    /// pinning down rather than trusting to a reading of the code.
    @Test("A real directory is never removed", arguments: Agent.allCases)
    func unlinkLeavesARealDirectory(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createDirectory(
            atPath: link(agent, paths), withIntermediateDirectories: true
        )
        let marker = (link(agent, paths) as NSString).appendingPathComponent("mine.txt")
        try "{}".write(toFile: marker, atomically: true, encoding: .utf8)

        _ = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test("A link pointing somewhere else is left alone", arguments: Agent.allCases)
    func unlinkLeavesAForeignLink(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createSymbolicLink(
            atPath: link(agent, paths), withDestinationPath: "somewhere-else"
        )
        _ = try runAm(["--unlink", agent.id], in: paths.root)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link(agent, paths))
        #expect(destination == "somewhere-else")
    }

    /// A link into `.agentmux/` is still not ours unless it points at this
    /// agent's own directory.
    @Test("A link at the wrong directory inside .agentmux/ is left alone")
    func unlinkLeavesALinkToTheWrongPlace() throws {
        let paths = try project()
        try FileManager.default.createSymbolicLink(
            atPath: paths.projectLink(for: .codex), withDestinationPath: ".agentmux/.claude"
        )
        _ = try runAm(["--unlink", "codex"], in: paths.root)

        let destination = try FileManager.default
            .destinationOfSymbolicLink(atPath: paths.projectLink(for: .codex))
        #expect(destination == ".agentmux/.claude")
    }

    @Test("A backup set aside earlier is never touched", arguments: Agent.allCases)
    func unlinkKeepsTheBackup(agent: Agent) throws {
        let paths = try project()
        try FileManager.default.createDirectory(
            atPath: backup(agent, paths), withIntermediateDirectories: true
        )
        _ = try runAm(["--link", agent.id], in: paths.root)
        _ = try runAm(["--unlink", agent.id], in: paths.root)
        #expect(FileManager.default.fileExists(atPath: backup(agent, paths)))
    }
}
