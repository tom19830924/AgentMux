import Foundation
import Testing

@testable import am

/// Everything between "the user typed `am claude`" and the agent taking over.
@Suite("Guards before launch", .serialized)
struct RunCommandGuardTests {
    @Test("With no gateways at all, it points at am add")
    func noGatewaysAtAll() throws {
        let paths = try projectFixture(gateways: .empty())
        let run = try runAm(["claude"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("am add"))
    }

    @Test("Gateways exist, but none supports this agent")
    func noGatewaySupportsTheAgent() throws {
        let paths = try projectFixture()  // claude only
        let run = try runAm(["codex"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("codex"))
    }

    @Test("An unknown -g lists the ones that exist")
    func unknownGatewayListsTheOnesThatExist() throws {
        let paths = try projectFixture()
        let run = try runAm(["claude", "-g", "nope"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("nope"))
        #expect(run.stderr.contains("alpha"))
    }

    /// Another gateway has to support codex, or the earlier "nothing supports
    /// this agent" guard fires first and this path is never reached.
    @Test("The named gateway has no such agent")
    func gatewayMissingTheAgent() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
            Gateway(id: "beta", label: nil, agents: ["codex": AgentConfig(args: [])]),
        ]))
        let run = try runAm(["codex", "-g", "alpha"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("alpha"))
        #expect(run.stderr.contains("beta"))  // the hint names what is available
    }

    /// Without a terminal there is no menu to show, so the error has to say
    /// how to pick a gateway instead of just failing.
    @Test("Without a terminal and without -g, it says to use -g")
    func noMenuWithoutATerminal() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
            Gateway(id: "beta", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
        ]))
        let run = try runAm(["claude"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("-g"))
    }

    /// The promise the whole design rests on: `ps aux` shows every command
    /// line on the machine, so a key must never reach one.
    @Test("A config that would leak a key to argv is refused")
    func refusesToPutAKeyOnTheCommandLine() throws {
        let paths = try projectFixture(
            gateways: GatewayFile(version: 1, gateways: [
                Gateway(id: "leaky", label: nil, agents: [
                    // Not a whole-field reference, so it is expanded inline
                    // rather than handed to apiKeyHelper — straight into argv.
                    "codex": AgentConfig(args: ["-c", "key=\"${secret:alpha_key}\""]),
                ]),
            ]),
            secrets: ["alpha_key": "sk-would-leak"]
        )
        let run = try runAm(["codex", "-g", "leaky"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("command line"))
        #expect(!run.stderr.contains("sk-would-leak"))
    }

    @Test("Last time's gateway is preselected")
    func lastChoiceIsPreselected() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
            Gateway(id: "beta", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
        ]))
        LaunchState.remember(gateway: "beta", for: .claude, in: paths.stateFile)

        let session = try TerminalSession(["claude", "--dry-run"], in: paths.root)
        try session.wait(for: "Choose a gateway")
        session.send("\r")
        #expect(try session.waitUntilExit() == 0)
        #expect(session.plain.contains("· beta"))
    }
}
