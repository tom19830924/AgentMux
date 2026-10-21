import Darwin
import Foundation

enum Key: Equatable {
    case up
    case down
    case enter
    case cancel
    case character(Character)
}

enum Terminal {
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    /// Settings to restore from the signal handler, which `defer` cannot reach.
    /// A handler may only touch async-signal-safe state, so these are plain
    /// globals rather than anything that locks.
    private nonisolated(unsafe) static var savedTermios = termios()
    private nonisolated(unsafe) static var savedTermiosIsValid = false
    private nonisolated(unsafe) static var handlerInstalled = false

    /// Ctrl-C arrives as a signal, which unwinds nothing: without this the
    /// process would die mid-prompt and leave the terminal in raw mode, where
    /// the shell no longer echoes what the user types.
    private static let restoreOnSignal: @convention(c) (Int32) -> Void = { signalNumber in
        if Terminal.savedTermiosIsValid {
            tcsetattr(STDIN_FILENO, TCSANOW, &Terminal.savedTermios)
        }
        _ = ansi.showCursorBytes.withUnsafeBufferPointer {
            Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
        }
        // Die of the original signal, so the exit status still says "interrupted".
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    private static func applying<T>(
        _ configure: (inout termios) -> Void, _ body: () throws -> T
    ) rethrows -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return try body() }

        savedTermios = original
        savedTermiosIsValid = true
        if !handlerInstalled {
            handlerInstalled = true
            signal(SIGINT, restoreOnSignal)
            signal(SIGTERM, restoreOnSignal)
        }

        var changed = original
        configure(&changed)
        tcsetattr(STDIN_FILENO, TCSANOW, &changed)

        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
            savedTermiosIsValid = false
        }
        return try body()
    }

    /// Runs `body` with the terminal in raw mode.
    ///
    /// The original settings come back through `defer` on every ordinary path,
    /// and through the signal handler when the process is killed outright.
    static func withRawMode<T>(_ body: () throws -> T) rethrows -> T {
        try applying({ raw in
            raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
            raw.c_cc.16 = 1  // VMIN: block until at least one byte
            raw.c_cc.17 = 0  // VTIME: no timeout
        }, {
            defer { write(ansi.showCursor) }
            return try body()
        })
    }

    /// Reads a secret, drawing one dot per character: the length shows, the
    /// value does not. Raw mode is what makes the substitution possible —
    /// with the terminal's own echo there is nothing to replace.
    ///
    /// `prefix` is reprinted on every redraw, since erasing a character means
    /// clearing the whole line.
    /// Reads a secret, drawing one dot per character: the length shows, the
    /// value does not. Raw mode is what makes the substitution possible — with
    /// the terminal's own echo there is nothing to replace.
    ///
    /// `prefix` is reprinted on every redraw, since erasing a character means
    /// clearing the whole line. The key handling itself lives in `SecretEntry`,
    /// where it can be tested without a terminal.
    static func readSecret(redrawing prefix: String) throws -> String {
        try withRawMode {
            var entry = SecretEntry()
            while true {
                guard let byte = readByte() else { throw CancelledError() }
                switch entry.feed(byte) {
                case let .done(value):
                    return value
                case .cancelled:
                    throw CancelledError()
                case .waiting:
                    let dots = String(repeating: "•", count: entry.maskLength)
                    write(ansi.clearLine + prefix + ansi.dim(dots))
                }
            }
        }
    }

    static func readKey() -> Key? {
        guard let first = readByte() else { return nil }
        switch first {
        case 0x03, 0x04: return .cancel          // Ctrl-C, Ctrl-D
        case 0x0D, 0x0A: return .enter
        case 0x1B:                                // ESC [ A/B, or bare ESC
            guard let second = readByte() else { return .cancel }
            guard second == 0x5B, let third = readByte() else { return .cancel }
            switch third {
            case 0x41: return .up
            case 0x42: return .down
            default: return nil
            }
        default:
            guard let scalar = Unicode.Scalar(UInt32(first)) else { return nil }
            return .character(Character(scalar))
        }
    }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }

    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

/// ANSI sequences and colours. Colour is dropped when the output is not a
/// terminal, or when NO_COLOR is set.
enum ansi {
    static let enabled: Bool =
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let showCursorBytes: [UInt8] = Array("\u{1B}[?25h".utf8)
    static let clearLine = "\u{1B}[2K\r"
    static func up(_ count: Int) -> String { count > 0 ? "\u{1B}[\(count)A" : "" }

    private static func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap("1", text) }
    static func dim(_ text: String) -> String { wrap("2", text) }
    static func red(_ text: String) -> String { wrap("31", text) }
    static func green(_ text: String) -> String { wrap("32", text) }
    static func cyan(_ text: String) -> String { wrap("36", text) }
}
