import Foundation
import Testing

@testable import am

/// What the user actually sees. These drive the real binary through a
/// pseudo-terminal, so `isatty` is true and raw mode takes effect — the escape
/// sequences and the signal handling are exercised rather than described.
@Suite("終端機畫面")
struct TerminalUITests {
    /// Answers up to and including the key prompt, leaving the cursor there.
    private func sessionAtKeyPrompt() throws -> (TerminalSession, String) {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "要設定哪個 agent")
        session.send("\r")
        try session.wait(for: "要連到哪裡")
        session.send("\r")
        try session.wait(for: "gateway 名稱")
        session.send("acme\r")
        try session.wait(for: "Base URL")
        session.send("https://api.example.com\r")
        try session.wait(for: "金鑰要用哪一把")
        session.send("\r")
        try session.wait(for: "金鑰名稱")
        session.send("\r")
        try session.wait(for: "貼上 acme_key 的值")
        return (session, root)
    }

    @Test("金鑰以圓點顯示，原文不出現在畫面上")
    func keyIsMasked() throws {
        let (session, _) = try sessionAtKeyPrompt()
        session.send("sk-SECRET")
        try session.wait(for: "•••••••••")

        #expect(!session.plain.contains("sk-SECRET"))
        session.interrupt()
    }

    @Test("退格會減少一個圓點")
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
    @Test("Ctrl-C 之後游標會被還原")
    func cursorComesBackAfterInterrupt() throws {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "要設定哪個 agent")
        #expect(session.raw.contains("\u{1B}[?25l"))  // 選單隱藏了游標

        session.clearCapture()
        session.interrupt()
        try session.wait(for: "\u{1B}[?25h")
    }

    @Test("中斷之後不留下任何檔案")
    func interruptLeavesNothing() throws {
        let root = try scratchDirectory()
        let session = try TerminalSession(["init"], in: root)
        try session.wait(for: "要設定哪個 agent")
        session.interrupt()
        _ = session.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: ProjectPaths(root: root).directory))
    }

    @Test("在真的終端機上走完 init，設定檔才出現")
    func fullRunThroughARealTerminal() throws {
        let (session, root) = try sessionAtKeyPrompt()
        session.send("sk-live\r")
        try session.wait(for: "模型")
        session.send("\r")
        #expect(session.waitUntilExit() == 0)

        let paths = ProjectPaths(root: root)
        #expect(try SecretStore.load(paths.secretsFile) == ["acme_key": "sk-live"])
        #expect(try GatewayStore.load(paths.configFile).gateways.map(\.id) == ["acme"])
    }
}
