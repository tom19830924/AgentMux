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

    /// Runs `body` with the terminal in raw mode.
    ///
    /// The original settings are restored through `defer`, so they come back on
    /// every path — including a thrown error. Leaving raw mode behind would
    /// hand the user a terminal that no longer echoes what they type.
    static func withRawMode<T>(_ body: () throws -> T) rethrows -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return try body() }

        var raw = original
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        raw.c_cc.16 = 1  // VMIN: block until at least one byte
        raw.c_cc.17 = 0  // VTIME: no timeout
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
            write(ansi.showCursor)
        }
        return try body()
    }

    /// Reads with echo disabled but line editing intact, for password entry.
    static func withoutEcho<T>(_ body: () throws -> T) rethrows -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return try body() }

        var quiet = original
        quiet.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &quiet)

        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
        }
        return try body()
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
