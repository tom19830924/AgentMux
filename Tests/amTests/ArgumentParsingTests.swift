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

    @Test("-g with nothing after it fails")
    func gatewayFlagNeedsAValue() throws {
        let paths = try projectFixture()
        for flag in ["-g", "--gateway"] {
            let run = try runAm(["claude", flag], in: paths.root)
            #expect(run.status != 0)
            #expect(run.stderr.contains("needs a gateway id after it"))
        }
    }

    @Test("The --gateway=name form is accepted")
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
    @Test("Cancelling with Ctrl-D exits 130")
    func cancellingExitsWith130() throws {
        let session = try TerminalSession(["init"], in: try scratchDirectory())
        try session.wait(for: "Which agent?")
        session.sendByte(0x04)
        #expect(try session.waitUntilExit() == 130)
    }
}
