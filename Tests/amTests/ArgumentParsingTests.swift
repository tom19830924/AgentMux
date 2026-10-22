import Foundation
import Testing

@testable import am

/// Everything `run(_:)` decides before a command gets involved.
@Suite("Argument parsing", .serialized)
struct ArgumentParsingTests {
    @Test("No arguments shows the help, not an error")
    func noArgumentsShowsHelp() throws {
        let run = try runAm([], in: try scratchDirectory())
        #expect(run.status == 0)
        #expect(run.stdout.contains("Usage:"))
    }

    /// The number here is what a bug report will quote, so it has to be the
    /// version that was actually installed.
    @Test("--version prints just the number")
    func versionPrintsTheNumber() throws {
        let root = try scratchDirectory()
        for flag in ["-v", "--version"] {
            let run = try runAm([flag], in: root)
            #expect(run.status == 0)
            #expect(run.stdout == "\(Build.version)\n")
        }
    }

    @Test("am secret without get shows the usage")
    func secretNeedsGet() throws {
        let run = try runAm(["secret", "list"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("am secret get"))
    }

    @Test("An unknown command lists the real ones")
    func unknownCommand() throws {
        let run = try runAm(["frobnicate"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("Unknown command"))
        #expect(run.stderr.contains("init"))
    }

    /// Said by the scan that looks for the agent rather than by the option
    /// loop: without the value it cannot tell whether the next word is the
    /// gateway's name or the agent's, so it never reaches that loop.
    @Test("-g with nothing after it fails")
    func gatewayFlagNeedsAValue() throws {
        let paths = try projectFixture()
        for flag in ["-g", "--gateway"] {
            let run = try runAm([flag], in: paths.root)
            #expect(run.status != 0)
            #expect(run.stderr.contains("needs a gateway id after it"))
        }
    }

    @Test("The --gateway=name form is accepted")
    func equalsFormIsAccepted() throws {
        let paths = try projectFixture()
        let run = try runAm(["--gateway=alpha", "--dry-run", "claude"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("alpha.example.com"))
    }

    // MARK: Combinations that cannot mean anything

    /// Each of these used to be accepted and then quietly dropped on the way
    /// to a branch that had already returned — the user believing they had
    /// asked for something.
    @Test("Two modes at once is refused, naming both")
    func twoModesAreRefused() throws {
        let run = try runAm(["--dry-run", "--link", "claude"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("--dry-run"))
        #expect(run.stderr.contains("--link"))
    }

    @Test("--link and --unlink together is refused")
    func linkAndUnlinkTogether() throws {
        let run = try runAm(["--link", "--unlink", "claude"], in: try scratchDirectory())
        #expect(run.status != 0)
    }

    @Test("--unlink with a gateway says it takes none")
    func unlinkTakesNoGateway() throws {
        let run = try runAm(["--unlink", "-g", "alpha", "claude"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("no gateway"))
    }

    /// Linking moves a directory; which gateway you use is settled at launch,
    /// so naming one here is a misunderstanding worth saying.
    @Test("--link with a gateway is refused for either agent", arguments: Agent.allCases)
    func linkTakesNoGateway(agent: Agent) throws {
        let paths = try projectFixture()
        let run = try runAm(["--link", "-g", "alpha", agent.id], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("no gateway"))
    }

    /// Neither starts the agent, so arguments meant for it would go nowhere.
    /// Dropping them quietly would leave a command line that did not do what
    /// it looks like it did.
    @Test("--link and --unlink refuse arguments meant for the agent",
          arguments: ["--link", "--unlink"])
    func linkRefusesPassthrough(flag: String) throws {
        let paths = try projectFixture()
        let run = try runAm([flag, "claude", "--resume", "abc"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("--resume abc"))
        #expect(!FileManager.default.fileExists(atPath: paths.projectLink(for: .claude)))
    }

    /// --dry-run is deliberately not in the test above: it stands in for a
    /// launch, so what it prints has to include what the agent would be given.
    @Test("--dry-run keeps the agent's own arguments and shows them")
    func dryRunKeepsPassthrough() throws {
        let paths = try projectFixture()
        let run = try runAm(["-g", "alpha", "--dry-run", "claude", "--resume", "abc"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("--resume abc"))
    }

    /// Two commands am prints as examples had the old argument order after the
    /// rule changed — the help's and this hint's. Reading the suggestion back
    /// and running it is the only check that cannot drift from what it says.
    @Test("The hint about -g prints a command am accepts")
    func gatewayHintIsRunnable() throws {
        let paths = try projectFixture()

        // No terminal here, so choosing a gateway falls back to the hint.
        let failed = try runAm(["claude"], in: paths.root)
        #expect(failed.status != 0)
        let suggestion = try #require(
            failed.stderr.components(separatedBy: "for example: ").last?
                .components(separatedBy: "\n").first
        )

        var words = suggestion.split(separator: " ").map(String.init)
        #expect(words.first == "am", "the hint should suggest an am command")
        words.removeFirst()

        let rerun = try runAm(words, in: paths.root)
        #expect(rerun.status == 0, "am printed \"\(suggestion)\", which it then refused")
    }

    @Test("With options but no agent, the error says an agent is missing")
    func noAgentNamed() throws {
        let run = try runAm(["--dry-run"], in: try projectFixture().root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("No agent to start"))
        for agent in Agent.allCases {
            #expect(run.stderr.contains(agent.id))
        }
    }

    // MARK: Where am's arguments end

    /// The agent's name ends am's own arguments, so a flag am would otherwise
    /// act on means nothing once it is past that point — including the one
    /// whose effect would be visible on disk.
    @Test("A mode flag after the agent reaches the agent instead")
    func modeFlagAfterTheAgentIsPassedOn() throws {
        let paths = try launchable()

        let run = try runAm(["-g", "alpha", "claude", "--link"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("--link"), "--link should have reached the agent")
        #expect(!FileManager.default.fileExists(atPath: paths.projectLink(for: .claude)))
    }

    /// Codex spells resume as a subcommand, with no leading dash. am used to
    /// refuse it as an unknown option, which is what made `--` necessary.
    @Test("A bare subcommand after the agent is passed straight on")
    func subcommandAfterTheAgentIsPassedOn() throws {
        let paths = try launchable()

        let run = try runAm(["-g", "alpha", "codex", "resume", "abc"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("resume"))
        #expect(run.stdout.contains("abc"))
    }

    /// `--` was the separator before the agent's name became one. Commands
    /// people already have keep working, and the agent is not handed a `--` it
    /// never asked for.
    @Test("A leading -- after the agent is swallowed, not forwarded")
    func oldSeparatorStillWorks() throws {
        let paths = try launchable()

        let run = try runAm(["-g", "alpha", "codex", "--", "resume", "abc"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("resume"))
        #expect(!run.stdout.contains("\"--\""), "the agent should not receive a bare --")
    }

    /// The value belongs to -g even when it reads like an agent's name, so the
    /// scan cannot simply stop at the first word that names one.
    @Test("A gateway named after an agent does not end am's arguments")
    func gatewayNamedLikeAnAgent() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "claude", label: nil, agents: [
                "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": "https://named.example.com"]),
            ]),
        ]))

        let run = try runAm(["-g", "claude", "--dry-run", "claude"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("named.example.com"))
    }

    private func launchable() throws -> ProjectPaths {
        try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: [
                "claude": AgentConfig(settings: [:]),
                "codex": AgentConfig(args: []),
            ]),
        ]))
    }

    // MARK: Combinations that do mean something

    @Test("A gateway with --dry-run still prints that gateway")
    func gatewayWithDryRun() throws {
        let paths = try projectFixture()
        let run = try runAm(["-g", "alpha", "--dry-run", "claude"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("alpha.example.com"))
    }

    @Test("--link on its own works for either agent", arguments: Agent.allCases)
    func plainLinkWorks(agent: Agent) throws {
        let paths = try projectFixture()
        #expect(try runAm(["--link", agent.id], in: paths.root).status == 0)
    }

    /// 130 is the shell's convention for "interrupted". Ctrl-C never reaches
    /// the program to produce it — the terminal driver turns that byte into
    /// SIGINT before any read sees it — so the exit code belongs to the keys
    /// that do arrive: Ctrl-D and Esc.
    @Test("Cancelling with Ctrl-D exits 130")
    func cancellingExitsWith130() throws {
        let session = try TerminalSession(["init"], in: try scratchDirectory())
        try session.wait(for: "Which agent?")
        session.sendByte(0x04)
        #expect(try session.waitUntilExit() == 130)
    }
}
