import Foundation
import Testing

@testable import am

/// What `--link` decides to do, before it touches anything. Keeping the
/// decision apart from the filesystem is what makes the awkward cases — a
/// directory already there, a link pointing somewhere else — testable at all.
@Suite("Deciding what to link")
struct LinkPlanTests {
    @Test("Nothing there: just create the link")
    func nothingInTheWay() {
        #expect(linkPlan(for: .missing) == .create)
    }

    @Test("Our own link: carry on rather than complain")
    func alreadyOurs() {
        #expect(linkPlan(for: .ourLink) == .create)
    }

    /// Moving the user's directory is the user's call, so the plan asks.
    @Test("A real directory has to be moved aside first")
    func directoryInTheWay() {
        #expect(linkPlan(for: .directory) == .askBeforeRenaming)
    }

    @Test("A link somewhere else is refused, not overwritten")
    func foreignLink() {
        #expect(linkPlan(for: .otherLink("../somewhere")) == .refuse)
    }

    @Test("A plain file where the link belongs is refused too")
    func fileInTheWay() {
        #expect(linkPlan(for: .file) == .refuse)
    }

    /// Relative, so moving the whole project does not break it, and named
    /// after the agent so two links never point at one directory.
    @Test("The target is relative and per agent", arguments: Agent.allCases)
    func targetShape(agent: Agent) {
        let target = relativeLinkTarget(for: agent)
        #expect(target == ".agentmux/\(agent.configDirectoryName)")
        #expect(!target.hasPrefix("/"))
    }
}

/// Worth saying once the link is in place, without stopping anything.
@Suite("Warnings after linking")
struct LinkWarningTests {
    private func repository(ignoring line: String?) throws -> ProjectPaths {
        let paths = try projectFixture()
        _ = try runGit(["init", "-q", "."], in: paths.root)
        if let line {
            try line.appending("\n")
                .write(toFile: (paths.root as NSString).appendingPathComponent(".gitignore"),
                       atomically: true, encoding: .utf8)
        }
        return paths
    }

    @Test("Reads what git actually ignores")
    func asksGit() throws {
        let paths = try repository(ignoring: ".claude")
        #expect(pathIsGitIgnored(paths.projectLink(for: .claude), in: paths.root))
        #expect(!pathIsGitIgnored(paths.configFile, in: paths.root))
    }

    /// Outside a repository there is no commit to worry about, so silence is
    /// the right answer rather than a warning nobody can act on.
    @Test("Outside a repository it stays quiet")
    func noRepositoryNoWarning() throws {
        let root = try scratchDirectory()
        #expect(pathIsGitIgnored((root as NSString).appendingPathComponent(".claude"), in: root))
    }

    @Test("Warns when the link would be committed", arguments: Agent.allCases)
    func warnsAboutAnUnignoredLink(agent: Agent) throws {
        let paths = try repository(ignoring: nil)
        #expect(linkWarnings(for: agent, paths: paths).contains { $0.contains("git-ignored") })
    }

    @Test("Says nothing when the link is already ignored", arguments: Agent.allCases)
    func quietWhenIgnored(agent: Agent) throws {
        let paths = try repository(ignoring: agent.configDirectoryName)
        #expect(linkWarnings(for: agent, paths: paths).isEmpty)
    }
}
