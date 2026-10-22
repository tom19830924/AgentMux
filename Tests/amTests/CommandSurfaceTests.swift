import Foundation
import Testing

@testable import am

/// What Claude Code's `apiKeyHelper` runs. Its whole job is to hand one value
/// to a pipe, so the shape of its output is part of the contract.
@Suite("am secret get")
struct SecretGetTests {
    private func project(_ secrets: [String: String]) throws -> ProjectPaths {
        let root = try scratchDirectory()
        let paths = ProjectPaths(root: root)
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: paths.configFile)
        try SecretStore.save(secrets, to: paths.secretsFile)
        return paths
    }

    /// A trailing newline would be taken as part of the key by whatever reads it.
    @Test("Prints the value with no trailing newline")
    func printsTheValueVerbatim() throws {
        let paths = try project(["k": "sk-value"])
        let run = try runAm(["secret", "get", "--file", paths.secretsFile, "k"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout == "sk-value")
    }

    @Test("Without --file it finds the project")
    func findsTheProjectSecrets() throws {
        let paths = try project(["k": "sk-from-project"])
        let run = try runAm(["secret", "get", "k"], in: paths.root)
        #expect(run.stdout == "sk-from-project")
    }

    @Test("An unknown name fails and prints nothing")
    func missingNameFails() throws {
        let paths = try project(["k": "sk-value"])
        let run = try runAm(["secret", "get", "--file", paths.secretsFile, "nope"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("nope"))
    }

    @Test("--file with no path shows the usage")
    func fileNeedsAPath() throws {
        let root = try scratchDirectory()
        let run = try runAm(["secret", "get", "--file"], in: root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("--file"))
    }
}

@Suite("Command surface")
struct CommandSurfaceTests {
    @Test("--help lists every command")
    func helpListsTheCommands() throws {
        let root = try scratchDirectory()
        let run = try runAm(["--help"], in: root)
        #expect(run.status == 0)
        for command in ["am init", "am add", "am ls"] {
            #expect(run.stdout.contains(command))
        }
    }

    /// It is how `apiKeyHelper` reaches a key, not something to type, so it is
    /// kept out of the help — while still working, because the settings am
    /// writes at every launch name it.
    @Test("am secret get is not advertised, and still works")
    func secretGetIsUnlistedButWorks() throws {
        let help = try runAm(["--help"], in: try scratchDirectory())
        #expect(!help.stdout.contains("am secret get"))

        let paths = try projectFixture(secrets: ["alpha_key": "sk-still-reachable"])
        let run = try runAm(["secret", "get", "alpha_key"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout == "sk-still-reachable")
    }

    /// The help is written by hand and the parser is another piece of code, so
    /// a flag can be added to one and forgotten in the other — which is how
    /// --link came to be described as something it only does for one agent.
    @Test("--help lists every flag the parser accepts")
    func helpListsEveryFlag() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        for flag in runModeFlags.map(\.flag) + ["-g", "--gateway", "--gateway=", "-h", "--help", "-v", "--version"] {
            #expect(run.stdout.contains(flag), "\(flag) is missing from --help")
        }
    }

    @Test("--help says the modes are one at a time")
    func helpSaysModesAreExclusive() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        #expect(run.stdout.contains("One of --dry-run, --link and --unlink at a time"))
    }

    /// The --link line went wrong three times by describing what it does for
    /// Claude as if it were both agents. It now describes one thing, which is
    /// all it does — and the test keeps the Claude-only wording out.
    @Test("The --link line describes one thing, true of both agents")
    func linkLineDoesNotOverclaim() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        let line = try #require(
            run.stdout.split(separator: "\n").first { $0.contains("--link ") }
        )
        for overclaim in ["this gateway", "the gateway", "extension"] {
            #expect(!line.contains(overclaim), "the --link line still claims \"\(overclaim)\"")
        }
    }

    /// The block used to list -h and -v, which the parser only accepts as the
    /// first word. A block that invites flags the parser refuses where it says
    /// to put them is worse than one that omits them.
    @Test("Every flag in the options block is accepted before the agent")
    func optionsAreAcceptedBeforeTheAgent() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        let block = try #require(
            run.stdout.components(separatedBy: "Options (before the agent's name):").last?
                .components(separatedBy: "\n\n").first
        )
        let flags = block
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .filter { $0.hasPrefix("-") }

        #expect(!flags.isEmpty)
        for flag in flags {
            let name = flag.components(separatedBy: "=")[0]
            // A value is supplied for the flags that take one; the ones that do
            // not will reject it, so only a complaint naming the flag counts.
            let result = try runAm([name, "x", "claude"], in: try scratchDirectory())
            #expect(
                !result.stderr.contains("does not know the option \"\(name)\""),
                "--help offers \(name) after an agent, but the parser refuses it"
            )
        }
    }

    @Test("--help says only --dry-run takes a gateway")
    func helpNamesTheGatewayRule() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        #expect(run.stdout.contains("Only --dry-run takes a gateway"))
    }

    @Test("--help names no particular provider")
    func helpNamesNoProvider() throws {
        let root = try scratchDirectory()
        let run = try runAm(["--help"], in: root)
        #expect(!run.stdout.lowercased().contains("mixroute"))
    }

    @Test("am ls shows the shape, never the key")
    func listShowsTheShape() throws {
        let root = try scratchDirectory()
        let paths = ProjectPaths(root: root)
        try FileManager.default.createDirectory(
            atPath: paths.directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(
            GatewayFile(version: 1, gateways: [
                Gateway(id: "alpha", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.example.com",
                        "ANTHROPIC_AUTH_TOKEN": "${secret:alpha_key}",
                    ])
                ])
            ]),
            to: paths.configFile
        )
        try SecretStore.save(["alpha_key": "sk-must-not-appear"], to: paths.secretsFile)

        let run = try runAm(["ls"], in: root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("alpha"))
        #expect(run.stdout.contains("claude"))
        #expect(run.stdout.contains("alpha_key"))
        #expect(!run.stdout.contains("sk-must-not-appear"))
    }

    @Test("am ls without a project points at init")
    func listWithoutAProject() throws {
        let run = try runAm(["ls"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("am init"))
    }
}

/// The helper command is embedded in a JSON settings blob and later run by a
/// shell, so anything unusual in a path has to survive the round trip.
@Suite("Shell quoting")
struct ShellQuoteTests {
    @Test("An ordinary value is single-quoted")
    func plainValue() {
        #expect(shellQuote("abc") == "'abc'")
    }

    @Test("Spaces do not split the argument")
    func spaces() {
        #expect(shellQuote("/path/with space/am") == "'/path/with space/am'")
    }

    @Test("A single quote is escaped")
    func singleQuote() {
        let quoted = shellQuote("it's")
        #expect(quoted == "'it'\\''s'")
    }

    @Test("The helper command carries the name, not the key")
    func helperMentionsOnlyTheName() {
        let command = secretHelperCommand(secretsFile: "/tmp/s.json", name: "alpha_key")
        #expect(command.contains("alpha_key"))
        #expect(command.contains("secret"))
        #expect(command.contains("/tmp/s.json"))
    }
}
