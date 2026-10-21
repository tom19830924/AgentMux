import Foundation
import Testing

@testable import am

/// The key handling behind the masked prompt. It is a value type on purpose:
/// the terminal supplies bytes, but none of these rules need one.
@Suite("金鑰輸入")
struct SecretEntryTests {
    private func feed(_ entry: inout SecretEntry, _ text: String) {
        for byte in Array(text.utf8) { _ = entry.feed(byte) }
    }

    @Test("一般字元會累積，遮罩長度等於字元數")
    func accumulates() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        #expect(entry.text == "sk-abc")
        #expect(entry.maskLength == 6)
    }

    @Test("Enter 結束輸入並交回完整的值")
    func enterFinishes() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        #expect(entry.feed(0x0D) == .done("sk-abc"))
    }

    @Test("退格刪掉一個字元")
    func backspace() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        _ = entry.feed(0x7F)
        #expect(entry.text == "sk-ab")
        #expect(entry.maskLength == 5)
    }

    /// A single character can span several bytes; deleting one byte at a time
    /// would leave the value holding an incomplete sequence.
    @Test("退格刪掉整個多位元組字元，不留半截")
    func backspaceMultibyte() {
        var entry = SecretEntry()
        feed(&entry, "金鑰")
        #expect(entry.maskLength == 2)
        _ = entry.feed(0x7F)
        #expect(entry.text == "金")
        #expect(entry.maskLength == 1)
    }

    @Test("空的時候退格不會出事")
    func backspaceOnEmpty() {
        var entry = SecretEntry()
        _ = entry.feed(0x7F)
        #expect(entry.text.isEmpty)
        #expect(entry.feed(0x0D) == .done(""))
    }

    @Test("Ctrl-U 清掉已經打的內容")
    func clearLine() {
        var entry = SecretEntry()
        feed(&entry, "sk-abc")
        _ = entry.feed(0x15)
        #expect(entry.text.isEmpty)
        #expect(entry.maskLength == 0)
    }

    @Test("Ctrl-C 與 Ctrl-D 都是取消")
    func cancels() {
        var a = SecretEntry(), b = SecretEntry()
        feed(&a, "sk-abc")
        #expect(a.feed(0x03) == .cancelled)
        #expect(b.feed(0x04) == .cancelled)
    }

    @Test("其他控制字元被忽略，不會進到值裡")
    func ignoresControlCharacters() {
        var entry = SecretEntry()
        feed(&entry, "sk-")
        for byte in [UInt8(0x09), 0x1B, 0x00, 0x07] { _ = entry.feed(byte) }
        feed(&entry, "abc")
        #expect(entry.text == "sk-abc")
    }

    @Test("遮罩按字元數算，不是位元組數")
    func maskCountsCharacters() {
        var entry = SecretEntry()
        feed(&entry, "金鑰abc")
        #expect(entry.text.utf8.count == 9)
        #expect(entry.maskLength == 5)
    }

    @Test("換行與歸位都當作結束")
    func bothNewlines() {
        var a = SecretEntry(), b = SecretEntry()
        feed(&a, "x"); feed(&b, "x")
        #expect(a.feed(0x0A) == .done("x"))
        #expect(b.feed(0x0D) == .done("x"))
    }
}
