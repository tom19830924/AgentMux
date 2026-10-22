/// A secret being typed, one byte at a time.
///
/// The terminal is where the bytes come from, but none of the rules below need
/// one — keeping them here means backspacing over a multi-byte character can be
/// tested without a tty, which is where the mistakes hide.
struct SecretEntry {
    enum Outcome: Equatable {
        /// Still typing; redraw the mask.
        case waiting
        /// Enter was pressed.
        case done(String)
        /// Ctrl-C or Ctrl-D.
        case cancelled
    }

    private var bytes: [UInt8] = []

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// How many dots to draw: characters, not bytes, or a pasted CJK key would
    /// show three times its length.
    var maskLength: Int { text.count }

    mutating func feed(_ byte: UInt8) -> Outcome {
        switch byte {
        case 0x03, 0x04:  // Ctrl-C, Ctrl-D
            return .cancelled

        case 0x0A, 0x0D:  // Enter
            return .done(text)

        case 0x7F, 0x08:  // Backspace
            // Drop the continuation bytes before the byte that leads them, so a
            // character leaves as a whole rather than a truncated sequence.
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
            if !bytes.isEmpty { bytes.removeLast() }
            return .waiting

        case 0x15:  // Ctrl-U, which clears the line in a shell too
            bytes.removeAll()
            return .waiting

        default:
            // Everything below space is a control key this prompt has no use
            // for; letting one through would put it inside the secret.
            if byte >= 0x20 { bytes.append(byte) }
            return .waiting
        }
    }
}
