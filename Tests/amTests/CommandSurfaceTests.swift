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
        for command in ["am init", "am add", "am ls", "am extension"] {
            #expect(run.stdout.contains(command))
        }
    }

    /// A mistyped command is told what it could have meant, and that list is
    /// written out by hand in a second place. This is the two drifting apart:
    /// a command added to the help and forgotten in the hint is one the error
    /// quietly denies exists.
    @Test("A mistyped command is offered every command the help lists")
    func theHintNamesEveryCommand() throws {
        let root = try scratchDirectory()
        let help = try runAm(["--help"], in: root).stdout
        let hint = try runAm(["nonsense"], in: root).stderr

        // Only the Usage block: the title line and the examples further down
        // also begin with "am", and neither is a list of commands.
        let advertised = help
            .components(separatedBy: "\n")
            .drop { $0.trimmingCharacters(in: .whitespaces) != "Usage:" }
            .dropFirst()
            .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("am ") else { return nil }
                let name = trimmed.dropFirst(3).prefix { !$0.isWhitespace }
                // Not commands: the agent placeholder and the flags.
                return name.hasPrefix("-") || name.hasPrefix("[") ? nil : String(name)
            }
        #expect(advertised.contains("extension"), Comment(rawValue: advertised.joined(separator: ",")))

        for command in advertised {
            #expect(hint.contains(command), "the hint does not name \(command): \(hint)")
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
    /// a flag can be added to one and forgotten in the other.
    @Test("--help lists every flag the parser accepts")
    func helpListsEveryFlag() throws {
        let run = try runAm(["--help"], in: try scratchDirectory())
        for flag in ["-g", "--gateway", "--gateway=", "--dry-run", "-h", "--help", "-v", "--version"] {
            #expect(run.stdout.contains(flag), "\(flag) is missing from --help")
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
