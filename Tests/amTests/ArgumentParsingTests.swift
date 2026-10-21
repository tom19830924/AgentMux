import Foundation
import Testing

@testable import am

/// Everything `run(_:)` decides before a command gets involved.
@Suite("參數解析")
struct ArgumentParsingTests {
    @Test("不帶參數時印出說明，而不是報錯")
    func noArgumentsShowsHelp() throws {
        let run = try runAm([], in: try scratchDirectory())
        #expect(run.status == 0)
        #expect(run.stdout.contains("用法："))
    }

    /// The number here is what a bug report will quote, so it has to be the
    /// version that was actually installed.
    @Test("--version 只印版本號")
    func versionPrintsTheNumber() throws {
        let root = try scratchDirectory()
        for flag in ["-v", "--version"] {
            let run = try runAm([flag], in: root)
            #expect(run.status == 0)
            #expect(run.stdout == "\(Build.version)\n")
        }
    }

    @Test("am secret 後面不是 get 就給出用法")
    func secretNeedsGet() throws {
        let run = try runAm(["secret", "list"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("am secret get"))
    }

    @Test("不認識的指令會列出可用的指令")
    func unknownCommand() throws {
        let run = try runAm(["frobnicate"], in: try scratchDirectory())
        #expect(run.status != 0)
        #expect(run.stderr.contains("不認識的指令"))
        #expect(run.stderr.contains("init"))
    }

    @Test("-g 後面沒接值會報錯")
    func gatewayFlagNeedsAValue() throws {
        let paths = try projectFixture()
        for flag in ["-g", "--gateway"] {
            let run = try runAm(["claude", flag], in: paths.root)
            #expect(run.status != 0)
            #expect(run.stderr.contains("後面要接"))
        }
    }

    @Test("--gateway=名稱 的寫法也認得")
    func equalsFormIsAccepted() throws {
        let paths = try projectFixture()
        let run = try runAm(["claude", "--gateway=alpha", "--dry-run"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("alpha.example.com"))
    }

    /// 130 is the shell's convention for "interrupted". Ctrl-C never reaches
    /// the program to produce it — the terminal driver turns that byte into
    /// SIGINT before any read sees it — so the exit code belongs to the keys
    /// that do arrive: Ctrl-D and Esc.
    @Test("用 Ctrl-D 取消互動，結束碼是 130")
    func cancellingExitsWith130() throws {
        let session = try TerminalSession(["init"], in: try scratchDirectory())
        try session.wait(for: "要設定哪個 agent")
        session.sendByte(0x04)
        #expect(try session.waitUntilExit() == 130)
    }
}
