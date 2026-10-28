import Foundation
import Testing

@testable import am

/// `am extension` writes two keys into `.claude/settings.local.json`, which is a
/// file `am` does not own: Claude Code keeps approvals and permission rules
/// there, and the user keeps their own variables and their own layout. So
/// every test here is really the same test — did anything else change?
@Suite("am extension", .serialized)
struct ExtensionCommandTests {
    private func project(
        secrets: [String: String] = ["linkai_key": "sk-one", "mixroute_key": "sk-two"]
    ) throws -> ProjectPaths {
        try projectFixture(
            gateways: GatewayFile(version: 1, gateways: [
                Gateway(id: "linkai", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.linkai.chat",
                        "ANTHROPIC_AUTH_TOKEN": "${secret:linkai_key}",
                    ]),
                ]),
                Gateway(id: "mixroute", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.mixroute.ai",
                        "ANTHROPIC_AUTH_TOKEN": "${secret:mixroute_key}",
                    ]),
                ]),
                Gateway(id: "anthropic", label: nil, agents: [
                    "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": ""]),
                ]),
            ]),
            secrets: secrets
        )
    }

    private func write(_ text: String, to paths: ProjectPaths) throws {
        try FileManager.default.createDirectory(
            atPath: (paths.claudeSettingsFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: paths.claudeSettingsFile, atomically: true, encoding: .utf8)
    }

    private func read(_ paths: ProjectPaths) throws -> String {
        try String(contentsOfFile: paths.claudeSettingsFile, encoding: .utf8)
    }

    private func parsed(_ paths: ProjectPaths) throws -> [String: Any] {
        let data = Data(try read(paths).utf8)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: Writing it the first time

    @Test("With no file, it writes one holding just the two keys")
    func createsTheFile() throws {
        let paths = try project()
        #expect(try extensionCommand(
            paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"])
        ) == 0)

        let object = try parsed(paths)
        #expect(object["apiKeyHelper"] as? String == "am secret get linkai_key")
        #expect((object["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
            == "https://api.linkai.chat")
        #expect(object.count == 2)
    }

    /// An absolute path would name this project inside a file that is supposed
    /// to survive being copied into the next one.
    @Test("The helper it writes carries no path")
    func theHelperIsRelative() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))

        let helper = try #require(parsed(paths)["apiKeyHelper"] as? String)
        #expect(helper == "am secret get linkai_key")
        #expect(!helper.contains("/"))
    }

    /// The file is read by an editor, shown in screenshots, and read over
    /// shoulders. It names a key; it never holds one.
    @Test("The key's value never reaches the file")
    func theKeyItselfStaysOut() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        #expect(!(try read(paths)).contains("sk-one"))
    }

    // MARK: Leaving the rest of the file alone

    @Test("Everything Claude Code put there survives")
    func otherKeysSurvive() throws {
        let paths = try project()
        try write("""
        {
          "enabledMcpjsonServers": [
            "github"
          ],
          "permissions": {
            "allow": [
              "Bash(swift build)"
            ]
          },
          "env": {
            "ANTHROPIC_MODEL": "claude-opus-5"
          }
        }

        """, to: paths)
        let before = try read(paths)

        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["mixroute", "mixroute_key"]))
        let after = try read(paths)
        let object = try parsed(paths)

        #expect(object["enabledMcpjsonServers"] as? [String] == ["github"])
        #expect(((object["permissions"] as? [String: Any])?["allow"] as? [String])
            == ["Bash(swift build)"])
        #expect((object["env"] as? [String: Any])?["ANTHROPIC_MODEL"] as? String
            == "claude-opus-5")

        // Every line that is not ours comes through spelled the same, in order.
        let ours = { (line: String) in
            line.contains("apiKeyHelper") || line.contains("ANTHROPIC_BASE_URL")
        }
        var remaining = after.components(separatedBy: "\n")[...]
        for line in before.components(separatedBy: "\n") where !ours(line) {
            let at = remaining.firstIndex { $0 == line || $0 == line + "," }
            #expect(at != nil, "a line was reformatted: \(line)")
            if let at { remaining = remaining[(at + 1)...] }
        }
        #expect(after.hasSuffix("\n"), "the trailing newline was not kept")
    }

    @Test("Indentation is whatever the file already used")
    func indentationIsKept() throws {
        let paths = try project()
        try write("{\n\t\"enabledMcpjsonServers\": [\n\t\t\"github\"\n\t]\n}\n", to: paths)

        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        let after = try read(paths)
        #expect(after.contains("\n\t\"apiKeyHelper\""), Comment(rawValue: after))
        #expect(!after.contains("\n  \"apiKeyHelper\""), Comment(rawValue: after))
    }

    @Test("Running it again replaces the two values and adds nothing")
    func secondRunReplaces() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["mixroute", "mixroute_key"]))

        let text = try read(paths)
        #expect(text.components(separatedBy: "apiKeyHelper").count - 1 == 1)
        #expect(text.components(separatedBy: "ANTHROPIC_BASE_URL").count - 1 == 1)

        let object = try parsed(paths)
        #expect(object["apiKeyHelper"] as? String == "am secret get mixroute_key")
        #expect((object["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
            == "https://api.mixroute.ai")
    }

    // MARK: Refusing rather than overwriting

    @Test("A file that is not valid JSON is left exactly as it was")
    func refusesBrokenJSON() throws {
        let paths = try project()
        let broken = "{ this is not json\n"
        try write(broken, to: paths)

        #expect(throws: AgentMuxError.self) {
            try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        }
        #expect(try read(paths) == broken)
    }

    @Test("An env that is not an object stops it")
    func refusesScalarEnv() throws {
        let paths = try project()
        let odd = #"{"env": "not an object"}"#
        try write(odd, to: paths)

        #expect(throws: AgentMuxError.self) {
            try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        }
        #expect(try read(paths) == odd)
    }

    @Test("A JSON array is not a settings file")
    func refusesArray() throws {
        let paths = try project()
        try write("[1, 2]", to: paths)
        #expect(throws: AgentMuxError.self) {
            try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        }
        #expect(try read(paths) == "[1, 2]")
    }

    @Test("Without a project it says to run am init")
    func needsAProject() throws {
        let run = try runAm(["extension"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("am init"))
    }

    @Test("Without a terminal it asks nothing and writes nothing")
    func needsATerminal() throws {
        let paths = try project()
        let run = try runAm(["extension"], in: paths.root)
        #expect(run.status != 0)
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettingsFile))
    }

    // MARK: Gateways and keys

    /// "Use Claude Code's own login" has no endpoint. Writing an empty string
    /// is how am says that everywhere else, and it is a replacement rather
    /// than the deletion this command never does.
    @Test("A gateway with no base URL writes an empty one")
    func officialGatewayWritesEmpty() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["anthropic"]))
        #expect((try parsed(paths)["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "")
    }

    /// Claude Code's own login fetches no key, so there is no key to pick and
    /// no helper to write. Asking would offer an answer that is wrong whichever
    /// one is chosen, and then write it down.
    @Test("The official gateway is not asked about a key")
    func officialGatewaySkipsTheKey() throws {
        let paths = try project()
        let prompter = ScriptedPrompter(["anthropic"])
        _ = try extensionCommand(paths: paths, prompter: prompter)

        #expect(prompter.asked == ["Which gateway?"])
        #expect(try parsed(paths)["apiKeyHelper"] == nil)
        #expect(!(try read(paths)).contains("apiKeyHelper"))
    }

    /// A helper left from an earlier gateway would quietly keep winning over
    /// the sign-in, which is the one way this could mislead. Emptying it is
    /// how Claude Code reads "unset", and it is a replacement — the same one
    /// the base URL gets — rather than the deletion this command never does.
    @Test("Choosing the official gateway empties a helper from an earlier one")
    func officialGatewayEmptiesTheHelper() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["anthropic"]))

        let object = try parsed(paths)
        #expect(object["apiKeyHelper"] as? String == "")
        #expect((object["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "")
        // Emptied, not removed: the line is still there to be read and edited.
        #expect((try read(paths)).contains("apiKeyHelper"))
    }

    /// Emptying is driven by the gateway being the sign-in one, not by it
    /// happening to name no key. A third-party endpoint reached without a key
    /// in `gateways.json` is still a third-party endpoint, and whatever helper
    /// is feeding it is the user's business.
    @Test("A third-party gateway that names no key leaves the helper alone")
    func keylessThirdPartyKeepsTheHelper() throws {
        let paths = try projectFixture(
            gateways: GatewayFile(version: 1, gateways: [
                Gateway(id: "local", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "http://localhost:8080",
                    ]),
                ]),
            ]),
            secrets: [:]
        )
        try write(#"{"apiKeyHelper": "/opt/my-own-script.sh"}"#, to: paths)

        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["local"]))
        #expect(try parsed(paths)["apiKeyHelper"] as? String == "/opt/my-own-script.sh")
    }

    /// Nothing to empty: a file that never had one does not gain an empty one.
    @Test("The official gateway adds no helper to a file without one")
    func officialGatewayAddsNoEmptyHelper() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["anthropic"]))
        #expect(!(try read(paths)).contains("apiKeyHelper"))
    }

    /// One endpoint is often reached with several keys, so the key is asked
    /// for rather than taken from the gateway.
    @Test("The key can differ from the one the gateway references")
    func keyIsChosenSeparately() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "mixroute_key"]))
        #expect(try parsed(paths)["apiKeyHelper"] as? String == "am secret get mixroute_key")
    }

    @Test("With no keys at all it writes the URL and leaves any helper alone")
    func noKeysLeavesTheHelper() throws {
        // No stored secrets and no gateway referencing one: only then is there
        // nothing to ask about. A name a gateway references still counts, the
        // same way `am add` offers it.
        let paths = try projectFixture(
            gateways: GatewayFile(version: 1, gateways: [
                Gateway(id: "linkai", label: nil, agents: [
                    "claude": AgentConfig(settings: [
                        "ANTHROPIC_BASE_URL": "https://api.linkai.chat",
                    ]),
                ]),
            ]),
            secrets: [:]
        )
        try write(#"{"apiKeyHelper": "something the user wrote"}"#, to: paths)

        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai"]))
        let object = try parsed(paths)
        #expect(object["apiKeyHelper"] as? String == "something the user wrote")
        #expect((object["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String
            == "https://api.linkai.chat")
    }

    // MARK: What it tells you

    /// Emptying the helper is the one thing here that discards something the
    /// file used to say. Printing the old value is what makes that recoverable,
    /// so it is part of the behaviour, not decoration.
    @Test("Emptying the helper prints what it used to be")
    func emptyingSaysWhatItWas() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        let prompter = ScriptedPrompter(["anthropic"])
        _ = try extensionCommand(paths: paths, prompter: prompter)

        // The old value has to be in the note about emptying, not merely
        // somewhere on screen: the "Currently:" block above prints it too, and
        // that one is gone from view by the time the value is overwritten.
        let note = try #require(
            prompter.notes.first { $0.contains("Emptied") },
            Comment(rawValue: "nothing was said about emptying: \(prompter.notes)")
        )
        #expect(note.contains("am secret get linkai_key"), Comment(rawValue: note))
    }

    @Test("Nothing is said about emptying when nothing was emptied")
    func noNoteWhenNothingChanged() throws {
        let paths = try project()
        let prompter = ScriptedPrompter(["linkai", "linkai_key"])
        _ = try extensionCommand(paths: paths, prompter: prompter)
        #expect(!prompter.notes.joined().contains("Emptied"), Comment(rawValue: prompter.notes.joined()))
    }

    /// The old values are shown before the questions, so the answer is given
    /// knowing what it replaces.
    @Test("The current two values are shown before anything is asked")
    func showsTheCurrentValuesFirst() throws {
        let paths = try project()
        _ = try extensionCommand(paths: paths, prompter: ScriptedPrompter(["linkai", "linkai_key"]))
        let prompter = ScriptedPrompter(["mixroute", "mixroute_key"])
        _ = try extensionCommand(paths: paths, prompter: prompter)

        let said = prompter.notes.joined()
        #expect(said.contains("https://api.linkai.chat"), Comment(rawValue: said))
        #expect(said.contains("am secret get linkai_key"), Comment(rawValue: said))
    }

    @Test("A file that is not there yet has no current values to show")
    func showsNothingForAFreshFile() throws {
        let paths = try project()
        let prompter = ScriptedPrompter(["linkai", "linkai_key"])
        _ = try extensionCommand(paths: paths, prompter: prompter)
        #expect(prompter.notes.isEmpty, Comment(rawValue: prompter.notes.joined()))
    }

    @Test("It asks for the gateway before the key")
    func asksInOrder() throws {
        let paths = try project()
        let prompter = ScriptedPrompter(["linkai", "linkai_key"])
        _ = try extensionCommand(paths: paths, prompter: prompter)
        #expect(prompter.asked == ["Which gateway?", "Which key?"])
    }
}

/// Editing JSON as text is what keeps a file's layout, and it is also how a
/// subtle mistake could drop a member or break a nesting. Before anything
/// reaches disk, the two documents are compared with our own two keys taken
/// out: they have to say the same thing. These tests are that check failing on
/// purpose, because a safety net nobody has ever seen catch anything is not
/// known to work.
@Suite("Refusing to write an edit that changed something else")
struct SettingsWriteVerificationTests {
    private func file() throws -> String {
        (try scratchDirectory() as NSString).appendingPathComponent("settings.local.json")
    }

    @Test("An edit that drops another key is refused")
    func refusesADroppedKey() throws {
        let path = try file()
        let before: [String: Any] = ["enabledMcpjsonServers": ["github"], "keep": 1]

        #expect(throws: AgentMuxError.self) {
            try writeVerifiedSettings(#"{"apiKeyHelper": "x"}"#, over: before, to: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path), "it wrote the file anyway")
    }

    @Test("An edit that changes another value is refused")
    func refusesAChangedValue() throws {
        let path = try file()
        let before: [String: Any] = ["enabledMcpjsonServers": ["github"]]

        #expect(throws: AgentMuxError.self) {
            try writeVerifiedSettings(#"{"enabledMcpjsonServers": ["other"]}"#, over: before, to: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("An edit that is no longer valid JSON is refused")
    func refusesBrokenResult() throws {
        let path = try file()
        #expect(throws: AgentMuxError.self) {
            try writeVerifiedSettings("{ broken", over: [:], to: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The two keys that are ours are exactly the ones allowed to differ.
    @Test("An edit that only touches our two keys goes through")
    func allowsOurOwnChanges() throws {
        let path = try file()
        let before: [String: Any] = [
            "enabledMcpjsonServers": ["github"],
            "env": ["ANTHROPIC_MODEL": "claude-opus-5"],
        ]
        let after = """
        {"enabledMcpjsonServers": ["github"], "apiKeyHelper": "am secret get k",
         "env": {"ANTHROPIC_MODEL": "claude-opus-5", "ANTHROPIC_BASE_URL": "https://x.example.com"}}
        """

        try writeVerifiedSettings(after, over: before, to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == after)
    }
}
