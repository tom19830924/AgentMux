import Foundation
import Testing

@testable import am

/// The key handling behind the masked prompt. It is a value type on purpose:
/// the terminal supplies bytes, but none of these rules need one.
@Suite("Typing a key")
struct SecretEntryTests {
    private func feed(_ entry: inout SecretEntry, _ text: String) {
        for byte in Array(text.utf8) { _ = entry.feed(byte) }
    }

    @Test("Ordinary characters accumulate, one dot each")
    func accumulates() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        #expect(entry.text == "sk-abc")
        #expect(entry.maskLength == 6)
    }

    @Test("Enter finishes and hands back the whole value")
    func enterFinishes() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        #expect(entry.feed(0x0D) == .done("sk-abc"))
    }

    @Test("Backspace removes one character")
    func backspace() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        _ = entry.feed(0x7F)
        #expect(entry.text == "sk-ab")
        #expect(entry.maskLength == 5)
    }

    /// A single character can span several bytes; deleting one byte at a time
    /// would leave the value holding an incomplete sequence.
    /// The CJK text here is the point: those characters are three bytes each,
    /// so a byte-at-a-time delete would leave a broken sequence behind.
    @Test("Backspace removes a multi-byte character whole")
    func backspaceMultibyte() {
        var entry = SecretEntry()
        feed(&entry, "金鑰")
        #expect(entry.maskLength == 2)
        _ = entry.feed(0x7F)
        #expect(entry.text == "金")
        #expect(entry.maskLength == 1)
    }

    @Test("Backspace on an empty entry is harmless")
    func backspaceOnEmpty() {
        var entry = SecretEntry()
        _ = entry.feed(0x7F)
        #expect(entry.text.isEmpty)
        #expect(entry.feed(0x0D) == .done(""))
    }

    @Test("Ctrl-U clears what was typed")
    func clearLine() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        _ = entry.feed(0x15)
        #expect(entry.text.isEmpty)
        #expect(entry.maskLength == 0)
    }

    @Test("Ctrl-C and Ctrl-D both cancel")
    func cancels() {
        var a = SecretEntry(), b = SecretEntry()
        feed(&a, "sk-abc")
        #expect(a.feed(0x03) == .cancelled)
        #expect(b.feed(0x04) == .cancelled)
    }

    @Test("Other control keys never reach the value")
    func ignoresControlCharacters() {
        var entry = SecretEntry()
        feed(&entry, "sk-")
        for byte in [UInt8(0x09), 0x1B, 0x00, 0x07] { _ = entry.feed(byte) }
        feed(&entry, "abc")
        #expect(entry.text == "sk-abc")
    }

    @Test("The mask counts characters, not bytes")
    func maskCountsCharacters() {
        var entry = SecretEntry()
        feed(&entry, "金鑰abc")
        #expect(entry.text.utf8.count == 9)
        #expect(entry.maskLength == 5)
    }

    @Test("Both newline and carriage return finish")
    func bothNewlines() {
        var a = SecretEntry(), b = SecretEntry()
        feed(&a, "x"); feed(&b, "x")
        #expect(a.feed(0x0A) == .done("x"))
        #expect(b.feed(0x0D) == .done("x"))
    }
}
