import Foundation
import Testing

@testable import am

/// `.claude/settings.local.json` is not ours. Claude Code writes approvals and
/// permission rules there, and whoever has been editing it chose how it looks.
/// So the one invariant worth more than all the others: everything we did not
/// come for stays exactly as it was, to the character.
@Suite("Editing JSON without reformatting it")
struct JSONTextEditTests {
    private let helper = ["apiKeyHelper"]
    private let baseURL = ["env", "ANTHROPIC_BASE_URL"]

    /// What the file says once our two keys are taken out of it. Two documents
    /// that agree here hold the same everything else.
    private func rest(of text: String) throws -> NSDictionary {
        let data = Data(text.utf8)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TestFailure("not a JSON object: \(text)") }
        object["apiKeyHelper"] = nil
        if var env = object["env"] as? [String: Any] {
            env["ANTHROPIC_BASE_URL"] = nil
            object["env"] = env.isEmpty ? nil : env
        }
        return object as NSDictionary
    }

    /// Lines that hold neither of our keys, which must come through untouched.
    private func otherLines(of text: String) -> [String] {
        text.components(separatedBy: "\n").filter {
            !$0.contains("apiKeyHelper") && !$0.contains("ANTHROPIC_BASE_URL")
        }
    }

    /// Every one of those lines still appears, in order, spelled the same.
    ///
    /// The one difference allowed is a comma: a new member needs the one
    /// before it to end with one, and that is JSON's grammar rather than a
    /// reformatting. Anything else — reindenting, reordering, rewrapping — is
    /// a line that no longer matches, and fails.
    private func linesSurvive(_ original: String, in edited: String) -> Bool {
        // A container written inline with nothing in it, `"env": {}`, is the
        // one line that has to change: its only member can go nowhere else,
        // and opening it out over three lines would be the reformatting this
        // is here to prevent.
        let wanted = otherLines(of: original)
            .filter { !($0.contains("\"env\"") && $0.contains("{}")) }
        var remaining = edited.components(separatedBy: "\n")[...]

        for line in wanted {
            guard let at = remaining.firstIndex(where: { $0 == line || $0 == line + "," })
            else { return false }
            remaining = remaining[(at + 1)...]
        }
        return true
    }

    private struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: The invariant, over every shape a real file takes

    static let fixtures: [(name: String, text: String)] = [
        ("two-space", """
        {
          "enabledMcpjsonServers": [
            "github"
          ]
        }
        """),
        ("four-space", """
        {
            "permissions": {
                "allow": [
                    "Bash(swift build)"
                ]
            }
        }
        """),
        ("tabs", "{\n\t\"enabledMcpjsonServers\": [\n\t\t\"github\"\n\t]\n}"),
        ("compact", #"{"enabledMcpjsonServers":["github"]}"#),
        ("empty object", "{}"),
        ("empty object, two lines", "{\n}"),
        ("empty env", """
        {
          "env": {}
        }
        """),
        ("env with other variables", """
        {
          "env": {
            "ANTHROPIC_MODEL": "claude-opus-5",
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
          }
        }
        """),
        ("both keys already set", """
        {
          "apiKeyHelper": "am secret get old_key",
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example.com"
          }
        }
        """),
        ("helper only", """
        {
          "apiKeyHelper": "am secret get old_key",
          "enabledMcpjsonServers": ["github"]
        }
        """),
        ("env only", """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example.com"
          }
        }
        """),
        ("awkward values", """
        {
          "note": "a \\" quote, a \\\\ backslash, 中文, a } brace",
          "permissions": { "allow": ["Bash(echo \\"hi\\")"] }
        }
        """),
        ("no trailing newline", "{\n  \"a\": 1\n}"),
        ("trailing newline", "{\n  \"a\": 1\n}\n"),
        ("nested objects in the way", """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "echo {}" }] }
            ]
          }
        }
        """),
    ]

    @Test("Everything but the two keys survives, to the character",
          arguments: fixtures)
    func onlyOurKeysChange(fixture: (name: String, text: String)) throws {
        let once = try #require(
            JSONTextEdit.setString("am secret get new_key", at: helper, in: fixture.text),
            "\(fixture.name): could not set apiKeyHelper"
        )
        let twice = try #require(
            JSONTextEdit.setString("https://new.example.com", at: baseURL, in: once),
            "\(fixture.name): could not set ANTHROPIC_BASE_URL"
        )

        // 1. Still JSON.
        let parsed = try #require(
            try? JSONSerialization.jsonObject(with: Data(twice.utf8)) as? [String: Any],
            "\(fixture.name): the result is not valid JSON:\n\(twice)"
        )

        // 2. Nothing else changed, in meaning.
        #expect(try rest(of: twice) == rest(of: fixture.text), "\(fixture.name): other keys changed")

        // 3. Nothing else changed, in text.
        if fixture.text.contains("\n") {
            #expect(linesSurvive(fixture.text, in: twice),
                    "\(fixture.name): a line was reformatted:\n\(twice)")
        } else {
            // A document written on one line stays on one line.
            #expect(!twice.contains("\n"), "\(fixture.name): was split over lines:\n\(twice)")
        }
        #expect(twice.hasSuffix("\n") == fixture.text.hasSuffix("\n"),
                "\(fixture.name): the trailing newline changed")

        // 4. Ours hold what we asked for.
        #expect(parsed["apiKeyHelper"] as? String == "am secret get new_key", "\(fixture.name)")
        let env = try #require(parsed["env"] as? [String: Any], "\(fixture.name): no env")
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://new.example.com", "\(fixture.name)")
    }

    /// Running it again must not append a second copy of either key.
    @Test("A second run replaces rather than repeats", arguments: fixtures)
    func repeatedRunsReplace(fixture: (name: String, text: String)) throws {
        var text = fixture.text
        for round in 1...3 {
            text = try #require(JSONTextEdit.setString("am secret get k\(round)", at: helper, in: text))
            text = try #require(JSONTextEdit.setString("https://h\(round).example.com", at: baseURL, in: text))
        }
        #expect(text.components(separatedBy: "apiKeyHelper").count - 1 == 1, "\(fixture.name)")
        #expect(text.components(separatedBy: "ANTHROPIC_BASE_URL").count - 1 == 1, "\(fixture.name)")

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(parsed["apiKeyHelper"] as? String == "am secret get k3")
    }

    // MARK: Layout

    @Test("An inserted member takes the indentation its siblings use")
    func insertionMatchesIndentation() throws {
        let tabs = "{\n\t\"a\": 1\n}"
        let edited = try #require(JSONTextEdit.setString("x", at: helper, in: tabs))
        #expect(edited.contains("\n\t\"apiKeyHelper\": \"x\""), Comment(rawValue: edited))

        let four = "{\n    \"a\": 1\n}"
        let edited4 = try #require(JSONTextEdit.setString("x", at: helper, in: four))
        #expect(edited4.contains("\n    \"apiKeyHelper\": \"x\""), Comment(rawValue: edited4))
    }

    @Test("A single-line document stays on one line")
    func compactStaysCompact() throws {
        let edited = try #require(JSONTextEdit.setString("x", at: helper, in: #"{"a":1}"#))
        #expect(!edited.contains("\n"), Comment(rawValue: edited))
        #expect(edited == #"{"a":1, "apiKeyHelper": "x"}"#, Comment(rawValue: edited))
    }

    @Test("An empty object gains one member and no stray comma")
    func emptyObjectGetsNoComma() throws {
        let edited = try #require(JSONTextEdit.setString("x", at: helper, in: "{}"))
        #expect(!edited.contains(",,"))
        #expect(edited == #"{"apiKeyHelper": "x"}"#, Comment(rawValue: edited))
    }

    @Test("A missing env is created with only the variable it needs")
    func missingEnvIsCreated() throws {
        let edited = try #require(
            JSONTextEdit.setString("https://x.example.com", at: baseURL, in: "{\n  \"a\": 1\n}")
        )
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any]
        )
        let env = try #require(parsed["env"] as? [String: Any])
        #expect(env.count == 1)
        #expect(parsed["a"] as? Int == 1)
    }

    // MARK: Values it must not be fooled by

    @Test("A brace or quote inside a string does not move the insertion point")
    func stringsAreNotScanned() throws {
        let text = #"{"note":"} \" { not real","a":1}"#
        let edited = try #require(JSONTextEdit.setString("x", at: helper, in: text))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any]
        )
        #expect(parsed["note"] as? String == #"} " { not real"#)
        #expect(parsed["apiKeyHelper"] as? String == "x")
    }

    @Test("A value with quotes or backslashes comes back out intact",
          arguments: [#"a "quoted" name"#, #"back\slash"#, "中文 key", "trailing \\"])
    func valuesAreEscaped(value: String) throws {
        let edited = try #require(JSONTextEdit.setString(value, at: helper, in: "{}"))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any]
        )
        #expect(parsed["apiKeyHelper"] as? String == value)
    }

    // MARK: Refusing

    @Test("Text that is not an object is refused", arguments: ["[1, 2]", "", "not json", "null"])
    func refusesNonObjects(text: String) {
        #expect(JSONTextEdit.setString("x", at: ["apiKeyHelper"], in: text) == nil)
    }

    @Test("A path through a non-object is refused")
    func refusesPathThroughScalar() {
        #expect(JSONTextEdit.setString("x", at: ["env", "A"], in: #"{"env": "not an object"}"#) == nil)
    }

    @Test("An empty path is refused")
    func refusesEmptyPath() {
        #expect(JSONTextEdit.setString("x", at: [], in: "{}") == nil)
    }
}
