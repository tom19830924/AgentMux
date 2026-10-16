import Foundation

/// An error whose message is meant to be read by the user. `main` prints it on
/// its own; anything else would surface as a crash.
struct AgentMuxError: Error {
    let message: String
    let hint: String?

    init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }
}

/// Thrown when the user aborts an interactive prompt (Ctrl-C / Esc).
struct CancelledError: Error {}
