import Foundation
import Testing

@testable import am

@Suite("What am ls reports")
struct ListStateTests {
    @Test("An empty project says how to add one")
    func emptyProject() throws {
        let paths = try projectFixture(gateways: .empty())
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.status == 0)
        #expect(run.stdout.contains("am add"))
    }

    /// Being told which key is missing is the difference between a fix and a
    /// hunt through two files.
    @Test("A referenced but unset key is named")
    func missingKeyIsNamed() throws {
        let paths = try projectFixture(secrets: [:])
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.stdout.contains("missing key"))
        #expect(run.stdout.contains("alpha_key"))
    }

    @Test("A label is shown with its id, which -g needs")
    func labelAndIdAreBothShown() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "alpha", label: "My Gateway", agents: [
                "claude": AgentConfig(settings: [:]),
            ]),
        ]))
        let run = try runAm(["ls"], in: paths.root)
        #expect(run.stdout.contains("My Gateway"))
        #expect(run.stdout.contains("alpha"))
    }

    @Test("A gateway needing no key says so")
    func noKeyNeeded() throws {
        let paths = try projectFixture(gateways: GatewayFile(version: 1, gateways: [
            Gateway(id: "official", label: nil, agents: [
                "claude": AgentConfig(settings: ["ANTHROPIC_BASE_URL": ""]),
            ]),
        ]))
        #expect(try runAm(["ls"], in: paths.root).stdout.contains("no key needed"))
    }

    @Test("A path under the current directory is shown relative")
    func pathIsShownRelative() {
        let current = FileManager.default.currentDirectoryPath
        #expect(relativeToCurrentDirectory("\(current)/a/b.json") == "a/b.json")
        #expect(relativeToCurrentDirectory("/somewhere/else.json") == "/somewhere/else.json")
    }
}

@Suite("Where the config is looked for")
struct DiscoveryBoundaryTests {
    /// Configuration is per project. Walking past the repository root would let
    /// one project silently adopt another's gateways.
    @Test("The search stops at the repository root")
    func stopsAtTheRepositoryRoot() throws {
        let outer = try scratchDirectory()
        try FileManager.default.createDirectory(
            atPath: ProjectPaths(root: outer).directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: ProjectPaths(root: outer).configFile)

        let inner = (outer as NSString).appendingPathComponent("repo/src")
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: ((outer as NSString).appendingPathComponent("repo") as NSString)
                .appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        #expect(ProjectPaths.discover(from: inner) == nil)
    }

    @Test("Without git, it finds the nearest project above")
    func findsTheNearestProject() throws {
        let root = try scratchDirectory()
        try FileManager.default.createDirectory(
            atPath: ProjectPaths(root: root).directory, withIntermediateDirectories: true
        )
        try GatewayStore.save(.empty(), to: ProjectPaths(root: root).configFile)

        let deep = (root as NSString).appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        #expect(ProjectPaths.discover(from: deep)?.root == root)
    }

    @Test("A missing config points at am init")
    func missingConfigPointsAtInit() throws {
        let error = #expect(throws: AgentMuxError.self) {
            try GatewayStore.load("/no/such/gateways.json")
        }
        #expect(error?.hint?.contains("am init") == true)
    }
}

@Suite("Edges of secret expansion")
struct SecretResolutionEdgeTests {
    private func resolver(_ secrets: [String: String] = ["k": "sk-1234567890"]) -> SecretResolver {
        SecretResolver(secrets: secrets, secretsFile: "/tmp/secrets.json")
    }

    @Test("An unclosed ${secret: is refused, not accepted quietly")
    func unterminatedReferenceIsRejected() {
        #expect(throws: AgentMuxError.self) {
            try resolver().resolve("Bearer ${secret:k")
        }
    }

    /// Showing three characters of a short key would be most of it.
    @Test("A key too short to hint at is masked whole")
    func shortValuesAreFullyMasked() {
        #expect(SecretResolver.mask(value: "sk-123") == "***")
        #expect(SecretResolver.mask(value: "sk-1234567890") == "sk-...7890")
    }

    @Test("Several references in one value all expand")
    func multipleReferencesInOneValue() throws {
        let resolved = try resolver(["a": "1", "b": "2"]).resolve("${secret:a}-${secret:b}")
        #expect(resolved == "1-2")
    }

    @Test("An unknown agent lists the supported ones")
    func unknownAgentIsNamed() {
        let error = #expect(throws: AgentMuxError.self) { try Agent.named("gemini") }
        #expect(error?.message.contains("gemini") == true)
        #expect(error?.hint?.contains("claude") == true)
    }

    @Test("A missing executable is reported as such")
    func missingExecutableIsReported() throws {
        let paths = try projectFixture()
        let run = try runAm(
            ["claude", "-g", "alpha"], in: paths.root,
            env: ["AGENTMUX_CLAUDE_COMMAND": "definitely-not-installed-xyz"]
        )
        #expect(run.status != 0)
        #expect(run.stderr.contains("Cannot find"))
    }
}
