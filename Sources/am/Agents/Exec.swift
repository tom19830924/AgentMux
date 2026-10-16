import Darwin
import Foundation

/// Replaces this process with the agent.
///
/// Unlike spawning a child, `execvp` hands the terminal, the exit status and
/// every signal straight to the agent — there is nothing left to forward, and
/// `am` cannot outlive or orphan it. The function only returns if the exec
/// fails.
func execAgent(command: String, args: [String], env: [String: String]) throws -> Never {
    for (key, value) in env { setenv(key, value, 1) }

    let argv: [UnsafeMutablePointer<CChar>?] =
        ([command] + args).map { strdup($0) } + [nil]
    defer { for pointer in argv where pointer != nil { free(pointer) } }

    execvp(command, argv)

    // Only reached when exec failed.
    if errno == ENOENT {
        throw AgentMuxError("找不到指令 \"\(command)\"", hint: "請確認它已安裝且在 PATH 上")
    }
    throw AgentMuxError("無法啟動 \"\(command)\"：\(String(cString: strerror(errno)))")
}
