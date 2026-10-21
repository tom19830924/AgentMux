import Foundation
import Testing

@testable import am

/// The key-name prompt sits directly above the one that takes the key itself,
/// and only the second is masked. Pasting into the first puts the key on the
/// screen, into the scrollback, and into secrets.json as a *name* — where
/// `am ls` will print it. The validator has to catch that.
@Suite("金鑰名稱的驗證")
struct SecretNameTests {
    @Test("一般名稱可以用")
    func ordinaryNamesPass() {
        for name in ["my-gateway_key", "acme_key", "k", "openai.prod", "KEY-2"] {
            #expect(secretNameProblem(name) == nil, "\(name) 應該要被接受")
        }
    }

    @Test("看起來像金鑰的字首會被擋下")
    func knownKeyPrefixesAreRejected() {
        for value in ["sk-abc123", "sk_live_abc", "ghp_abcdef", "xai-abc", "AIzaSyAbc"] {
            #expect(secretNameProblem(value) != nil, "\(value) 應該要被擋下")
        }
    }

    @Test("太長的字串會被擋下，因為名稱不會那麼長")
    func longValuesAreRejected() {
        #expect(secretNameProblem(String(repeating: "a", count: 41)) != nil)
        #expect(secretNameProblem(String(repeating: "a", count: 40)) == nil)
    }

    @Test("被擋下時說明這裡要填的是名稱，而不是只說格式錯誤")
    func theMessageExplainsTheMixUp() {
        #expect(secretNameProblem("sk-abcdefghijk")?.contains("名稱") == true)
    }

    @Test("特殊字元照樣被擋")
    func illegalCharactersStillRejected() {
        #expect(secretNameProblem("has space") != nil)
        #expect(secretNameProblem("has/slash") != nil)
        #expect(secretNameProblem("") != nil)
    }
}
