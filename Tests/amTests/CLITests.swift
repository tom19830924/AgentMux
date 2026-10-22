import Foundation
import Testing

@testable import am

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()       // amTests
    .deletingLastPathComponent()       // Tests
    .deletingLastPathComponent()       // package root

/// The most recently built `am` binary.
///
/// `Bundle.main` points at swiftpm's test runner rather than the products
/// directory, and the build path differs between `swift build` and Xcode, so
/// the binary is located by searching the build directory instead.
private let binary: URL = {
    let build = packageRoot.appendingPathComponent(".build")
    let enumerator = FileManager.default.enumerator(
        at: build, includingPropertiesForKeys: [.isExecutableKey, .contentModificationDateKey]
    )
    var newest: (URL, Date)?
    while let url = enumerator?.nextObject() as? URL {
        guard url.lastPathComponent == "am" else { continue }
        let values = try? url.resourceValues(forKeys: [.isExecutableKey, .contentModificationDateKey])
        guard values?.isExecutable == true, let date = values?.contentModificationDate else { continue }
        if newest == nil || date > newest!.1 { newest = (url, date) }
    }
    guard let found = newest?.0 else {
        fatalError("No built am found — run swift build first")
    }
    return found
}()

private let fakeAgent = packageRoot
    .appendingPathComponent("Tests/Fixtures/fake-agent.sh").path

private struct Run {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func am(_ arguments: [String], in directory: String, env extra: [String: String] = [:]) throws -> Run {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var environment = ProcessInfo.processInfo.environment
    environment["AGENTMUX_CLAUDE_COMMAND"] = fakeAgent
    environment["AGENTMUX_CODEX_COMMAND"] = fakeAgent
    // The real shell exports these; they must not decide the outcome.
    environment["ANTHROPIC_BASE_URL"] = "https://inherited.example"
    environment["NO_COLOR"] = "1"
    for (key, value) in extra { environment[key] = value }
    process.environment = environment

    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return Run(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

private let token = "sk-cli-test-TOKEN-value"

private func project() throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("am-cli-\(UUID().uuidString)").path
    let paths = ProjectPaths(root: root)
    try FileManager.default.createDirectory(atPath: paths.directory, withIntermediateDirectories: true)
    try GatewayStore.save(
        GatewayFile(version: 1, gateways: [
            Gateway(id: "my-gateway", label: nil, agents: [
                "claude": AgentConfig(settings: [
                    "ANTHROPIC_BASE_URL": "https://api.example.com",
                    "ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}",
                ]),
                "codex": AgentConfig(
                    args: ["-c", "model_provider=\"agentmux\""],
                    env: ["AGENTMUX_FAKE_KEY": "${secret:my-gateway_key}"]
                ),
            ]),
        ]),
        to: paths.configFile
    )
    try SecretStore.save(["my-gateway_key": token], to: paths.secretsFile)
    return root
}

private struct Report: Decodable {
    let argv: [String]
    let env: [String: String]
    let helperKey: String?
}

@Suite("Launching")
struct CLITests {
    @Test("No key in the argv handed to execvp; the helper fetches it")
    func noSecretInArgv() throws {
        let run = try am(["-g", "my-gateway", "claude"], in: try project())
        #expect(run.status == 0)

        let report = try JSONDecoder().decode(Report.self, from: Data(run.stdout.utf8))
        #expect(!report.argv.joined(separator: " ").contains(token))
        #expect(report.helperKey == token)
    }

    @Test("A Codex key travels only in the environment")
    func codexKeyInEnv() throws {
        let run = try am(["-g", "my-gateway", "codex"], in: try project())
        let report = try JSONDecoder().decode(Report.self, from: Data(run.stdout.utf8))

        #expect(report.env["AGENTMUX_FAKE_KEY"] == token)
        #expect(!report.argv.joined(separator: " ").contains(token))
    }

    @Test("Arguments after the agent follow the gateway's own, untouched")
    func passthrough() throws {
        let run = try am(["-g", "my-gateway", "codex", "resume", "abc"], in: try project())
        let report = try JSONDecoder().decode(Report.self, from: Data(run.stdout.utf8))

        #expect(report.argv.suffix(2) == ["resume", "abc"])
        #expect(report.argv.first == "-c")
    }

    @Test("The agent's exit code is passed straight back")
    func exitCode() throws {
        let run = try am(["-g", "my-gateway", "codex"], in: try project(), env: ["FAKE_AGENT_EXIT": "42"])
        #expect(run.status == 42)
    }

    @Test("A launch writes no temporary files")
    func noTempFiles() throws {
        // Hand the launch a temporary directory of its own. The shared one also
        // holds the scratch projects that tests running in parallel create, so
        // sampling it would pick those up instead of anything the launch wrote.
        let directory = try project()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        _ = try am(["-g", "my-gateway", "claude"], in: directory, env: ["TMPDIR": temporary.path])

        let written = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        #expect(written.isEmpty)
    }

    @Test("--dry-run starts nothing and prints no key")
    func dryRun() throws {
        let run = try am(["-g", "my-gateway", "--dry-run", "claude"], in: try project())

        #expect(run.status == 0)
        #expect(!run.stdout.contains(token))
        #expect(run.stdout.contains("my-gateway_key"))   // only the name
        #expect(run.stdout.contains("apiKeyHelper"))
        #expect(!run.stdout.contains("\"argv\""))      // the agent never ran
    }

    /// Before the agent's name, am owns every word, so one it does not know is
    /// an error — and the fix is a position, not a separator.
    @Test("An unknown option before the agent says to move it after")
    func unknownOption() throws {
        let run = try am(["--resume", "claude"], in: try project())
        #expect(run.status == 1)
        #expect(run.stderr.contains("--resume"))
        #expect(run.stderr.contains("am claude --resume"))
    }

    @Test("With no config it points at am init")
    func missingConfig() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-empty-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)

        let run = try am(["-g", "x", "claude"], in: empty)
        #expect(run.status == 1)
        #expect(run.stderr.contains("am init"))
    }

    @Test("A subdirectory finds the project above it")
    func discoversUpward() throws {
        let root = try project()
        let nested = (root as NSString).appendingPathComponent("a/b")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)

        #expect(try am(["-g", "my-gateway", "claude"], in: nested).status == 0)
    }

    @Test("Without a terminal, init and add refuse outright")
    func requiresTTY() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-tty-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)

        let run = try am(["init"], in: empty)
        #expect(run.status == 1)
        #expect(run.stderr.contains("interactive terminal"))
        #expect(!FileManager.default.fileExists(
            atPath: ProjectPaths(root: empty).directory))
    }
}
