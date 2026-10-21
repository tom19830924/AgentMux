import Foundation

/// Expands `${secret:NAME}` references and remembers every secret value it
/// handed out, so the caller can mask them before printing anything and refuse
/// to put them on a command line.
final class SecretResolver {
    private let secrets: [String: String]
    private let secretsFile: String
    /// secret value -> secret name
    private(set) var disclosed: [String: String] = [:]

    init(secrets: [String: String], secretsFile: String) {
        self.secrets = secrets
        self.secretsFile = secretsFile
    }

    convenience init(file: String) throws {
        self.init(secrets: try SecretStore.load(file), secretsFile: file)
    }

    func has(_ name: String) -> Bool { secrets[name] != nil }

    var names: [String] { secrets.keys.sorted() }

    func resolve(_ raw: String) throws -> String {
        var result = ""
        var rest = Substring(raw)

        while let range = rest.range(of: "${secret:") {
            result += rest[rest.startIndex..<range.lowerBound]
            let afterOpen = rest[range.upperBound...]
            guard let close = afterOpen.firstIndex(of: "}") else {
                throw AgentMuxError("設定裡有沒有結尾的 ${secret:...}")
            }
            let name = String(afterOpen[afterOpen.startIndex..<close])
            result += try value(of: name)
            rest = afterOpen[afterOpen.index(after: close)...]
        }

        return result + rest
    }

    func resolve(_ raw: [String: String]?) throws -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw ?? [:] { out[key] = try resolve(value) }
        return out
    }

    func value(of name: String) throws -> String {
        guard let value = secrets[name] else {
            throw AgentMuxError(
                "找不到 secret \"\(name)\"",
                hint: "請在 \(secretsFile) 加上 \"\(name)\": \"<金鑰>\""
            )
        }
        if !value.isEmpty { disclosed[value] = name }
        return value
    }

    func containsSecret(_ text: String) -> Bool {
        disclosed.keys.contains { text.contains($0) }
    }

    /// Replaces every disclosed secret with `sk-...last4 (secret:name)`.
    func mask(_ text: String) -> String {
        var out = text
        for (value, name) in disclosed {
            out = out.replacingOccurrences(of: value, with: "\(Self.mask(value: value)) (secret:\(name))")
        }
        return out
    }

    static func mask(value: String) -> String {
        guard value.count > 8 else { return "***" }
        return "\(value.prefix(3))...\(value.suffix(4))"
    }
}

/// Names referenced by `${secret:...}` inside a template, without resolving them.
func secretReferences(in raw: String) -> [String] {
    var names: [String] = []
    var rest = Substring(raw)
    while let range = rest.range(of: "${secret:") {
        let afterOpen = rest[range.upperBound...]
        guard let close = afterOpen.firstIndex(of: "}") else { break }
        names.append(String(afterOpen[afterOpen.startIndex..<close]))
        rest = afterOpen[afterOpen.index(after: close)...]
    }
    return names
}

enum SecretStore {
    static func load(_ file: String) throws -> [String: String] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw AgentMuxError(
                "無法解析 \(file)",
                hint: "這個檔案必須是一個 JSON 物件，例如 { \"my-gateway_key\": \"sk-...\" }"
            )
        }
    }

    /// Writes one named secret, keeping the file at 0600.
    static func write(name: String, value: String, to file: String) throws {
        var secrets = try load(file)
        secrets[name] = value
        try save(secrets, to: file)
    }

    static func save(_ secrets: [String: String], to file: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(secrets) + Data("\n".utf8)
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        // `atomic` replaces the file, so the mode is reapplied after every write.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}
