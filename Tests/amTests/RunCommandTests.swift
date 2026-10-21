import Foundation
import Testing

@testable import am

/// Everything between "the user typed `am claude`" and the agent taking over.
@Suite("啟動前的把關")
struct RunCommandGuardTests {
    @Test("一個 gateway 都沒有時，指向 am add")
    func noGatewaysAtAll() throws {
        let paths = try projectFixture(gateways: .empty())
        let run = try runAm(["claude"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("am add"))
    }

    @Test("有 gateway 但沒有一個支援這個 agent")
    func noGatewaySupportsTheAgent() throws {
        let paths = try projectFixture()  // 只設定了 claude
        let run = try runAm(["codex"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("codex"))
    }

    @Test("-g 指到不存在的 gateway 時列出有哪些")
    func unknownGatewayListsTheOnesThatExist() throws {
        let paths = try projectFixture()
        let run = try runAm(["claude", "-g", "nope"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("nope"))
        #expect(run.stderr.contains("alpha"))
    }

    /// Another gateway has to support codex, or the earlier "nothing supports
    /// this agent" guard fires first and this path is never reached.
    @Test("-g 的 gateway 沒有設定這個 agent")
    func gatewayMissingTheAgent() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
            Gateway(id: "beta", label: nil, agents: ["codex": AgentConfig(args: [])]),
        ]))
        let run = try runAm(["codex", "-g", "alpha"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("alpha"))
        #expect(run.stderr.contains("beta"))  // 提示可用的是哪些
    }

    /// Without a terminal there is no menu to show, so the error has to say
    /// how to pick a gateway instead of just failing.
    @Test("非互動環境又沒給 -g 時，提示改用 -g")
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
    @Test("設定會讓金鑰進到命令列時，當場擋下不啟動")
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
        #expect(run.stderr.contains("命令列"))
        #expect(!run.stderr.contains("sk-would-leak"))
    }

    @Test("上次選過的 gateway 會是選單的預設項")
    func lastChoiceIsPreselected() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
            Gateway(id: "beta", label: nil, agents: ["claude": AgentConfig(settings: [:])]),
        ]))
        LaunchState.remember(gateway: "beta", for: .claude, in: paths.stateFile)

        let session = try TerminalSession(["claude", "--dry-run"], in: paths.root)
        try session.wait(for: "選擇 gateway")
        session.send("\r")
        #expect(try session.waitUntilExit() == 0)
        #expect(session.plain.contains("· beta"))
    }
}
