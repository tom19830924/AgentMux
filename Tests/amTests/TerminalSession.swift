import Darwin
import Foundation
import Testing

@testable import am

/// The most recently built `am` binary.
///
/// `Bundle.main` points at swiftpm's test runner rather than the products
/// directory, and the build path differs between `swift build` and Xcode, so
/// the binary is located by searching the build directory instead.
let amBinary: URL = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let enumerator = FileManager.default.enumerator(
        at: packageRoot.appendingPathComponent(".build"),
        includingPropertiesForKeys: [.isExecutableKey, .contentModificationDateKey]
    )
    var newest: (URL, Date)?
    while let url = enumerator?.nextObject() as? URL {
        guard url.lastPathComponent == "am" else { continue }
        let values = try? url.resourceValues(forKeys: [.isExecutableKey, .contentModificationDateKey])
        guard values?.isExecutable == true, let date = values?.contentModificationDate else { continue }
        if newest == nil || date > newest!.1 { newest = (url, date) }
    }
    guard let found = newest?.0 else { fatalError("找不到已建置的 am，請先執行 swift build") }
    return found
}()

let fakeAgentPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/fake-agent.sh").path

func scratchDirectory() throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("am-tty-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}



/// A project with one gateway that both agents can use, for the tests that
/// need something to launch rather than something to configure.
@discardableResult
func projectFixture(
    gateways: GatewayFile? = nil, secrets: [String: String] = ["alpha_key": "sk-fixture-value"]
) throws -> ProjectPaths {
    let paths = ProjectPaths(root: try scratchDirectory())
    try FileManager.default.createDirectory(
        atPath: paths.directory, withIntermediateDirectories: true
    )
    let config = gateways ?? GatewayFile(version: 1, gateways: [
        Gateway(id: "alpha", label: nil, agents: [
            "claude": AgentConfig(settings: [
                "ANTHROPIC_BASE_URL": "https://alpha.example.com",
                "ANTHROPIC_AUTH_TOKEN": "${secret:alpha_key}",
            ]),
        ]),
    ])
    try GatewayStore.save(config, to: paths.configFile)
    try SecretStore.save(secrets, to: paths.secretsFile)
    return paths
}

/// Runs `am` with pipes rather than a terminal, for the paths that produce
/// plain output. A pty would rewrite the line endings these assert on.
@discardableResult
func runAm(
    _ arguments: [String], in directory: String, env extra: [String: String] = [:]
) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = amBinary
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var environment = ProcessInfo.processInfo.environment
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
    return (
        process.terminationStatus,
        String(decoding: outData, as: UTF8.self),
        String(decoding: errData, as: UTF8.self)
    )
}

/// Runs `am` with a pseudo-terminal on both ends, which is what makes the
/// interactive paths reachable from a test: `isatty` answers yes, `tcsetattr`
/// takes effect, and everything the UI draws can be read back and asserted on.
///
/// Signals are delivered with `kill` rather than by writing Ctrl-C, because the
/// child is not a session leader here and so the pty generates none itself.
final class TerminalSession {
    private let primary: Int32
    private let process = Process()
    private var captured = Data()

    init(_ arguments: [String], in directory: String, env extra: [String: String] = [:]) throws {
        var primaryFD: Int32 = 0
        var replicaFD: Int32 = 0
        guard openpty(&primaryFD, &replicaFD, nil, nil, nil) == 0 else {
            throw TerminalSessionError("openpty 失敗：\(String(cString: strerror(errno)))")
        }
        primary = primaryFD
        _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL, 0) | O_NONBLOCK)

        let replica = FileHandle(fileDescriptor: replicaFD, closeOnDealloc: false)
        process.executableURL = amBinary
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = replica
        process.standardOutput = replica
        process.standardError = replica

        var environment = ProcessInfo.processInfo.environment
        environment["AGENTMUX_CLAUDE_COMMAND"] = fakeAgentPath
        environment["AGENTMUX_CODEX_COMMAND"] = fakeAgentPath
        // NO_COLOR is deliberately left unset: these tests assert on what the
        // escape sequences do.
        environment["NO_COLOR"] = nil
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        try process.run()
        // The parent's copy would otherwise keep the pty open past the child's exit.
        close(replicaFD)
    }

    // MARK: Input

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(primary, $0.baseAddress, $0.count) }
    }

    func sendByte(_ byte: UInt8) {
        var value = byte
        _ = Darwin.write(primary, &value, 1)
    }

    func interrupt() { kill(process.processIdentifier, SIGINT) }

    // MARK: Output

    /// Everything written so far, escape sequences intact.
    var raw: String {
        drain()
        return String(decoding: captured, as: UTF8.self)
    }

    /// The same text with the escape sequences removed, for matching on words.
    var plain: String { Self.strippingEscapes(raw) }

    /// The last non-empty line drawn. Redraws return the cursor with a carriage
    /// return rather than a newline, so those count as separate lines here.
    var latestLine: String {
        plain.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Forgets what has been captured, so an assertion can speak about what
    /// happens next rather than what the screen already held.
    func clearCapture() {
        drain()
        captured.removeAll()
    }

    @discardableResult
    func wait(for substring: String, timeout: TimeInterval = 10) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = raw
            if text.contains(substring) || Self.strippingEscapes(text).contains(substring) {
                return text
            }
            usleep(20_000)
        }
        throw TerminalSessionError(
            "等不到 \"\(substring)\"。目前畫面：\n\(plain)"
        )
    }

    /// Waits with a deadline: a prompt that never returns would otherwise hang
    /// the whole suite instead of failing it.
    @discardableResult
    func waitUntilExit(timeout: TimeInterval = 10) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw TerminalSessionError("行程在 \(timeout) 秒內沒有結束。畫面：\n\(plain)")
            }
            drain()
            usleep(20_000)
        }
        process.waitUntilExit()
        drain()
        return process.terminationStatus
    }

    // MARK: Internals

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(primary, &buffer, buffer.count)
            guard count > 0 else { break }
            captured.append(contentsOf: buffer[0..<count])
        }
    }

    private static func strippingEscapes(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let escape = rest.firstIndex(of: "\u{1B}") {
            output += rest[rest.startIndex..<escape]
            var index = rest.index(after: escape)
            // CSI sequences run until a byte in the @-~ range ends them.
            if index < rest.endIndex, rest[index] == "[" {
                index = rest.index(after: index)
                while index < rest.endIndex, !("@"..."~").contains(rest[index]) {
                    index = rest.index(after: index)
                }
            }
            if index < rest.endIndex { index = rest.index(after: index) }
            rest = rest[index...]
        }
        return output + rest
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        close(primary)
    }
}

struct TerminalSessionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
