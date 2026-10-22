import Foundation
import Testing

@testable import am

/// What the user actually sees. These drive the real binary through a
/// pseudo-terminal, so `isatty` is true and raw mode takes effect — the escape
/// sequences and the signal handling are exercised rather than described.
@Suite("What the screen shows", .serialized)
struct TerminalUITests {
    /// Answers up to and including the key prompt, leaving the cursor there.
    private func sessionAtKeyPrompt() throws -> (TerminalSession, String) {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "Which agent?")
        session.send("\r")
        try session.wait(for: "Connect to what?")
        session.send("\r")
        try session.wait(for: "Gateway name")
        session.send("acme\r")
        try session.wait(for: "Base URL")
        session.send("https://api.example.com\r")
        try session.wait(for: "Which key?")
        session.send("\r")
        try session.wait(for: "Name for this key")
        session.send("\r")
        try session.wait(for: "Paste the value for acme_key")
        return (session, root)
    }

    @Test("The key is drawn as dots and never appears")
    func keyIsMasked() throws {
        let (session, _) = try sessionAtKeyPrompt()
        session.send("sk-SECRET")
        try session.wait(for: "•••••••••")

        #expect(!session.plain.contains("sk-SECRET"))
        session.interrupt()
    }

    @Test("Backspace takes away a dot")
    func backspaceRemovesADot() throws {
        let (session, _) = try sessionAtKeyPrompt()
        session.send("abcd")
        try session.wait(for: "••••")
        session.clearCapture()
        session.sendByte(0x7F)
        try session.wait(for: "•••")

        #expect(!session.latestLine.contains("••••"))
        session.interrupt()
    }

    /// The menu hides the cursor. A signal unwinds nothing, so without the
    /// handler the cursor would stay hidden in the user's shell afterwards —
    /// and unlike the terminal modes, no shell puts it back.
    @Test("The cursor comes back after Ctrl-C")
    func cursorComesBackAfterInterrupt() throws {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "Which agent?")
        #expect(session.raw.contains("\u{1B}[?25l"))  // the menu hid the cursor

        session.clearCapture()
        session.interrupt()
        try session.wait(for: "\u{1B}[?25h")
    }

    @Test("An interrupt leaves no files behind")
    func interruptLeavesNothing() throws {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "Which agent?")
        session.interrupt()
        _ = try session.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: ProjectPaths(root: root).directory))
    }

    @Test("init through a real terminal writes only at the end")
    func fullRunThroughARealTerminal() throws {
        let (session, root) = try sessionAtKeyPrompt()
        session.send("sk-live\r")
        try session.wait(for: "Ready")
        #expect(try session.waitUntilExit() == 0)

        let paths = ProjectPaths(root: root)
        #expect(try SecretStore.load(paths.secretsFile) == ["acme_key": "sk-live"])
        #expect(try GatewayStore.load(paths.configFile).gateways.map(\.id) == ["acme"])
    }

    // MARK: Linking

    /// Linking chooses no gateway, so it never asks which one.
    @Test("--link asks nothing when the way is clear")
    func linkAsksNothingWhenClear() throws {
        let paths = try projectFixture()
        let session = try TerminalSession(["--link", "claude"], in: paths.root)
        try session.wait(for: "Linked")
        #expect(try session.waitUntilExit() == 0)
        #expect(!session.plain.contains("Choose a gateway"))
    }

    /// Moving the user's directory needs the user, so it asks first and acts
    /// only after the answer.
    @Test("--link asks before moving an existing directory aside")
    func linkAsksBeforeRenaming() throws {
        let paths = try projectFixture()
        try FileManager.default.createDirectory(
            atPath: paths.projectLink(for: .claude), withIntermediateDirectories: true
        )
        let session = try TerminalSession(["--link", "claude"], in: paths.root)
        try session.wait(for: "already exists")
        session.send("\r")
        try session.wait(for: "Linked")
        #expect(try session.waitUntilExit() == 0)
        #expect(FileManager.default.fileExists(atPath: paths.linkBackup(for: .claude)))
    }

    @Test("Cancelling that question leaves the directory alone")
    func cancellingTheRenameChangesNothing() throws {
        let paths = try projectFixture()
        try FileManager.default.createDirectory(
            atPath: paths.projectLink(for: .claude), withIntermediateDirectories: true
        )
        let session = try TerminalSession(["--link", "claude"], in: paths.root)
        try session.wait(for: "already exists")
        session.send("\u{1B}[B\r")
        _ = try session.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: paths.linkBackup(for: .claude)))
        #expect(!FileManager.default.fileExists(atPath: paths.linkedDirectory(for: .claude)))
    }

    // MARK: Menu navigation

    private func menuSession() throws -> TerminalSession {
        let session = try TerminalSession(["init"], in: try scratchDirectory())
        try session.wait(for: "Which agent?")
        return session
    }

    @Test("Arrow down moves the selection")
    func arrowDownMovesTheSelection() throws {
        let session = try menuSession()
        session.send("\u{1B}[B\r")
        try session.wait(for: "· Codex CLI")
        session.interrupt()
    }

    /// Two items, so pressing up from the first lands on the last.
    @Test("Arrow up from the first wraps to the last")
    func arrowUpWrapsAround() throws {
        let session = try menuSession()
        session.send("\u{1B}[A\r")
        try session.wait(for: "· Codex CLI")
        session.interrupt()
    }

    @Test("j and k move like the arrow keys")
    func viKeysMove() throws {
        let session = try menuSession()
        session.send("j\r")
        try session.wait(for: "· Codex CLI")
        session.interrupt()
    }

    @Test("A rejected answer is explained and asked again")
    func validationAsksAgain() throws {
        let session = try menuSession()
        session.send("\r")
        try session.wait(for: "Connect to what?")
        session.send("\r")
        try session.wait(for: "Gateway name")

        session.send("has a space\r")
        try session.wait(for: "Letters, digits")
        // The rejection and the re-ask land together, so count the prompt
        // rather than waiting for a second one to arrive.
        let asked = session.plain.components(separatedBy: "Gateway name").count - 1
        #expect(asked >= 2)

        session.send("fine-name\r")
        try session.wait(for: "Base URL")
        session.interrupt()
    }
}
