import Foundation
import Testing

@testable import am

/// `--dry-run`, `--link` and `--unlink` each end the run somewhere different,
/// so asking for two of them asks for two different things. Deciding this up
/// front, from the arguments alone, keeps the rule out of the launch path.
@Suite("Which mode the flags ask for")
struct RunModeTests {
    @Test("No mode flag means launching the agent")
    func defaultsToLaunching() throws {
        #expect(try runMode(from: ["-g", "alpha"]) == .launch)
    }

    @Test("Each flag names its own mode")
    func eachFlagIsAMode() throws {
        #expect(try runMode(from: ["--dry-run"]) == .dryRun)
        #expect(try runMode(from: ["--link"]) == .link)
        #expect(try runMode(from: ["--unlink"]) == .unlink)
    }

    @Test("Two modes is a question with no answer")
    func twoModesIsRefused() throws {
        let error = #expect(throws: AgentMuxError.self) {
            try runMode(from: ["--dry-run", "--link"])
        }
        #expect(error?.message.contains("--dry-run") == true)
        #expect(error?.message.contains("--link") == true)
    }

    @Test("Every pair of modes is refused, whichever order")
    func everyPairIsRefused() throws {
        let flags = ["--dry-run", "--link", "--unlink"]
        for first in flags {
            for second in flags where second != first {
                #expect(throws: AgentMuxError.self) { try runMode(from: [first, second]) }
            }
        }
    }

    /// Saying the same thing twice is not a contradiction.
    @Test("The same flag repeated is still one mode")
    func repeatingAFlagIsFine() throws {
        #expect(try runMode(from: ["--link", "--link"]) == .link)
    }

    @Test("A gateway is not a mode, so it never conflicts with one")
    func gatewayIsNotAMode() throws {
        #expect(try runMode(from: ["-g", "alpha", "--link"]) == .link)
        #expect(try runMode(from: ["--gateway=alpha", "--dry-run"]) == .dryRun)
    }
}
