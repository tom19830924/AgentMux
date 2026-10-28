import Foundation
import Testing

@testable import am

/// A session started through `am` looks the same whichever gateway it is on,
/// which is the whole problem: one base URL can be reached with several keys,
/// and nothing on screen says which one this is. Claude Code's status line
/// runs a command and shows what it prints, and everything worth showing here
/// is known before the agent starts — so it is written into the command
/// rather than looked up by it, and the command stays a `printf`.
@Suite("Gateway in Claude Code's status line", .serialized)
struct StatusLineTests {
    private func claude(
        baseURL: String = "https://api.example.com/v1/", token: String? = "${secret:alpha_key}"
    ) -> AgentConfig {
        var settings = ["ANTHROPIC_BASE_URL": baseURL]
        if let token { settings["ANTHROPIC_AUTH_TOKEN"] = token }
        return AgentConfig(settings: settings)
    }

    private func project(
        statusLine: Bool?, label: String? = nil, claude: AgentConfig? = nil
    ) throws -> ProjectPaths {
        var file = GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: label, agents: [
                "claude": claude ?? self.claude(),
                "codex": AgentConfig(args: []),
            ]),
        ])
        file.statusLine = statusLine
        return try projectFixture(gateways: file)
    }

    private func command(in paths: ProjectPaths) throws -> String {
        let run = try runAm(["-g", "alpha", "--dry-run", "claude"], in: paths.root)
        #expect(run.status == 0)
        return run.stdout
    }

    // MARK: Whether it appears at all

    /// Our status line replaces whatever the user already had, and costs the
    /// footer's keyboard hints. Neither is ours to decide for them.
    @Test("Off unless the project asks for it")
    func absentByDefault() throws {
        #expect(!(try command(in: try project(statusLine: nil))).contains("statusLine"))
    }

    @Test("statusLine: false is the same as not asking")
    func explicitFalse() throws {
        #expect(!(try command(in: try project(statusLine: false))).contains("statusLine"))
    }

    // MARK: What it says

    /// runAm sets NO_COLOR, so these see the plain form.
    @Test("It names the gateway, the key and where it points")
    func showsAllThreeFields() throws {
        let out = try command(in: try project(statusLine: true))
        #expect(out.contains("gateway: %s, key: %s, host: %s"))
        #expect(out.contains("'alpha' 'alpha_key' 'api.example.com'"))
    }

    /// The menu shows the label, so the status line has to agree with what was
    /// picked rather than with the id underneath it.
    @Test("A labelled gateway shows the label, not the id")
    func showsTheLabel() throws {
        let out = try command(in: try project(statusLine: true, label: "Work account"))
        #expect(out.contains("'Work account'"))
    }

    /// "Use the CLI's own login" has no key and no endpoint of its own. Empty
    /// labels would say less than nothing.
    @Test("A gateway with no key and no base URL shows only its name")
    func officialGatewayShowsOnlyTheName() throws {
        let paths = try project(statusLine: true, claude: claude(baseURL: "", token: ""))
        let out = try command(in: paths)
        #expect(out.contains("printf 'gateway: %s' 'alpha'"))
        #expect(!out.contains("key:"))
        #expect(!out.contains("host:"))
    }

    /// The host is the part worth reading; the path is noise that would push
    /// the rest of the line off a narrow terminal.
    @Test("Only the host of the base URL is shown, not the whole thing")
    func showsTheHostOnly() throws {
        let fields = statusLineFields(
            gateway: Gateway(id: "alpha", label: nil, agents: [:]),
            config: claude(baseURL: "https://api.example.com/v1/messages")
        )
        #expect(fields.map(\.label) == ["gateway", "key", "host"])
        #expect(fields.last?.value == "api.example.com")
    }

    /// A base URL built from a secret never reaches the status line, because
    /// resolving it would put the key on a command line and `am` refuses the
    /// launch outright. The field is dropped as well, for the case the check
    /// cannot see: an empty secret, which it does not count as disclosed.
    @Test("A base URL that references a secret never gets that far")
    func secretInTheURLIsNotShown() throws {
        let paths = try project(
            statusLine: true, claude: claude(baseURL: "https://${secret:alpha_key}.example.com")
        )
        let run = try runAm(["-g", "alpha", "--dry-run", "claude"], in: paths.root)
        #expect(run.status != 0)
        #expect(run.stderr.contains("key on the command line"))

        let fields = statusLineFields(
            gateway: Gateway(id: "alpha", label: nil, agents: [:]),
            config: claude(baseURL: "https://${secret:alpha_key}.example.com")
        )
        #expect(fields.map(\.label) == ["gateway", "key"])
    }

    /// A key named in the config but never shown by value: the status line is
    /// on screen, in screenshots, and over shoulders.
    @Test("The key's name is shown, never anything that could be its value")
    func showsTheKeyNameNotTheKey() throws {
        let out = try command(in: try project(statusLine: true))
        #expect(out.contains("alpha_key"))
        #expect(!out.contains("sk-fixture-value"))
    }

    // MARK: How it is built

    /// A label is free text. As a format string its `%` would eat whatever
    /// came after it, and a quote would end the command early.
    @Test("A label that looks like shell or printf syntax is neutralised",
          arguments: ["100% done", "it's here", "a b;c", "$HOME", "`id`"])
    func awkwardLabelsAreQuoted(label: String) throws {
        let gateway = Gateway(id: "alpha", label: label, agents: [:])
        let command = statusLineCommand(
            for: gateway, config: AgentConfig(settings: [:]), colour: false
        )

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()

        #expect(printed == "gateway: \(label)")
    }

    /// The colours pass through JSON, a command line and a shell before a
    /// terminal sees them, so what matters is what the shell prints.
    @Test("With colour, only the values are coloured and the labels are left alone")
    func colouredFormRendersThroughAShell() throws {
        let gateway = Gateway(id: "alpha", label: "Work 100%", agents: [:])
        let command = statusLineCommand(for: gateway, config: claude(), colour: true)

        // No literal control bytes on the command line; `ps` stays readable.
        #expect(!command.contains("\u{1B}"))

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()

        let e = "\u{1B}"
        #expect(printed == "gateway: \(e)[36mWork 100%\(e)[0m, "
            + "key: \(e)[36malpha_key\(e)[0m, host: \(e)[36mapi.example.com\(e)[0m")
    }

    @Test("NO_COLOR drops the escapes and keeps every word")
    func noColourIsPlain() throws {
        let gateway = Gateway(id: "alpha", label: nil, agents: [:])
        let plain = statusLineCommand(for: gateway, config: claude(), colour: false)
        #expect(!plain.contains("033"))
        #expect(plain == "printf 'gateway: %s, key: %s, host: %s' 'alpha' 'alpha_key' 'api.example.com'")
    }

    // MARK: Elsewhere

    /// Codex's status line is a fixed list of built-in items with no room for
    /// one of ours, so asking for it must not change what Codex is handed.
    @Test("Codex is handed nothing extra")
    func codexIsUnaffected() throws {
        let on = try runAm(["-g", "alpha", "--dry-run", "codex"], in: try project(statusLine: true).root)
        let off = try runAm(["-g", "alpha", "--dry-run", "codex"], in: try project(statusLine: nil).root)
        #expect(on.status == 0)
        #expect(!on.stdout.contains("statusLine"))
        #expect(on.stdout == off.stdout)
    }

    /// Files written before this setting existed have to keep loading.
    @Test("A gateways.json without the key still loads")
    func olderFileStillLoads() throws {
        let paths = try projectFixture()
        let raw = """
        {"version":1,"gateways":[{"id":"alpha","agents":{"claude":{"settings":{}}}}]}
        """
        try raw.write(toFile: paths.configFile, atomically: true, encoding: .utf8)

        let loaded = try GatewayStore.load(paths.configFile)
        #expect(loaded.statusLine == nil)
        #expect(try runAm(["-g", "alpha", "--dry-run", "claude"], in: paths.root).status == 0)
    }

    /// Saving a file that never asked for it must not start asking.
    @Test("Saving a file without the setting does not add it")
    func savingKeepsItAbsent() throws {
        let paths = try projectFixture()
        try GatewayStore.save(GatewayFile(version: 1, gateways: []), to: paths.configFile)
        let text = try String(contentsOfFile: paths.configFile, encoding: .utf8)
        #expect(!text.contains("statusLine"))
    }
}
