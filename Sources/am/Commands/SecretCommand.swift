import Foundation

/// Prints one secret to stdout. This is what Claude Code's `apiKeyHelper` runs:
/// the key is fetched only when the agent actually needs it and travels through
/// a pipe, so it is never written to disk for the launch and never appears on a
/// command line.
func secretGetCommand(_ arguments: [String]) throws -> Int32 {
    var secretsFile: String?
    var rest: [String] = []

    var index = 0
    while index < arguments.count {
        if arguments[index] == "--file" {
            guard index + 1 < arguments.count else {
                throw AgentMuxError("--file needs a path after it")
            }
            secretsFile = arguments[index + 1]
            index += 2
        } else {
            rest.append(arguments[index])
            index += 1
        }
    }

    guard let name = rest.first else {
        throw AgentMuxError("Usage: am secret get [--file <path>] <name>")
    }

    let file = try secretsFile ?? ProjectPaths.require().secretsFile
    let secrets = try SecretStore.load(file)
    guard let value = secrets[name] else {
        throw AgentMuxError("No secret named \"\(name)\"", hint: "Check that \(file) has that key")
    }

    // No trailing newline: the consumer uses the output verbatim.
    FileHandle.standardOutput.write(Data(value.utf8))
    return 0
}
