/// Changes one value in a JSON document without reformatting the rest of it.
///
/// `.claude/settings.local.json` belongs to Claude Code and to whoever has been
/// editing it: approvals, permission rules, whatever indentation they chose.
/// Parsing it into a dictionary and writing it back would preserve the content
/// and lose everything else, so `am` edits the text instead and leaves every
/// byte it did not come for exactly where it was.
///
/// This is not a JSON parser. It finds one member of one object and either
/// replaces its value or appends a new member beside its siblings. Anything it
/// cannot place with certainty it refuses, and the caller falls back to
/// reporting rather than guessing — see `verifiedEdit(of:)`.
enum JSONTextEdit {
    /// Sets `path` (one or two levels, e.g. `["env", "ANTHROPIC_BASE_URL"]`) to
    /// a string value, creating the intermediate object and the member when
    /// they are absent. Returns nil when the text is not shaped as expected.
    static func setString(_ value: String, at path: [String], in text: String) -> String? {
        guard !path.isEmpty else { return nil }
        var characters = Array(text)
        guard let root = objectRange(in: characters, from: 0) else { return nil }
        return apply(value, path: path[...], within: root, to: &characters)
            ? String(characters) : nil
    }

    // MARK: Walking the text

    private struct Range {
        /// Index of `{`.
        let open: Int
        /// Index of the matching `}`.
        let close: Int
    }

    /// The first object at or after `start`, with its matching close brace.
    private static func objectRange(in characters: [Character], from start: Int) -> Range? {
        var index = start
        while index < characters.count, characters[index] != "{" { index += 1 }
        guard index < characters.count, let close = matchingBrace(in: characters, from: index)
        else { return nil }
        return Range(open: index, close: close)
    }

    /// Scans forward from an opening brace or bracket to the one that closes
    /// it, counting nesting and skipping anything inside a string.
    private static func matchingBrace(in characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < characters.count {
            switch characters[index] {
            case "\"":
                guard let end = endOfString(in: characters, from: index) else { return nil }
                index = end
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index += 1
        }
        return nil
    }

    /// The index of the closing quote of the string that starts at `open`.
    private static func endOfString(in characters: [Character], from open: Int) -> Int? {
        var index = open + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "\"" { return index }
            index += 1
        }
        return nil
    }

    /// Where a value ends, given the index it starts at.
    private static func endOfValue(in characters: [Character], from start: Int) -> Int? {
        switch characters[start] {
        case "\"": return endOfString(in: characters, from: start)
        case "{", "[": return matchingBrace(in: characters, from: start)
        default:
            // A number, true, false or null: it ends where its line or its
            // sibling list does.
            var index = start
            while index < characters.count, !",}]\n\r".contains(characters[index]) { index += 1 }
            var end = index - 1
            while end > start, characters[end].isWhitespace { end -= 1 }
            return end
        }
    }

    /// The members of an object, in the order they appear.
    private struct Member {
        let name: String
        /// Index of the opening quote of the member's name.
        let nameStart: Int
        let valueStart: Int
        /// Index of the last character of the value.
        let valueEnd: Int
    }

    private static func members(in characters: [Character], of object: Range) -> [Member]? {
        var found: [Member] = []
        var index = object.open + 1

        while index < object.close {
            switch characters[index] {
            case " ", "\t", "\n", "\r", ",":
                index += 1
            case "\"":
                guard let nameEnd = endOfString(in: characters, from: index) else { return nil }
                let name = String(characters[(index + 1)...(nameEnd - 1)])

                var colon = nameEnd + 1
                while colon < object.close, characters[colon].isWhitespace { colon += 1 }
                guard colon < object.close, characters[colon] == ":" else { return nil }

                var valueStart = colon + 1
                while valueStart < object.close, characters[valueStart].isWhitespace {
                    valueStart += 1
                }
                guard valueStart < object.close,
                      let valueEnd = endOfValue(in: characters, from: valueStart)
                else { return nil }

                found.append(Member(
                    name: unescaped(name), nameStart: index,
                    valueStart: valueStart, valueEnd: valueEnd
                ))
                index = valueEnd + 1
            default:
                return nil
            }
        }
        return found
    }

    /// Only the escapes a settings key can realistically carry; a name this
    /// does not understand simply will not match the one we are looking for,
    /// which leaves the document untouched rather than wrongly edited.
    private static func unescaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Editing

    private static func apply(
        _ value: String, path: ArraySlice<String>, within object: Range,
        to characters: inout [Character]
    ) -> Bool {
        guard let name = path.first, let existing = members(in: characters, of: object)
        else { return false }
        let rest = path.dropFirst()
        let member = existing.first { $0.name == name }

        if rest.isEmpty {
            guard let member else {
                insert(member: "\"\(escaped(name))\": \"\(escaped(value))\"",
                       into: object, after: existing, to: &characters)
                return true
            }
            // Replace the value and nothing else: the quotes around it, the
            // spacing before it and the comma after it all stay as they were.
            let replacement = Array("\"\(escaped(value))\"")
            characters.replaceSubrange(member.valueStart...member.valueEnd, with: replacement)
            return true
        }

        guard let member else {
            // The intermediate object is missing, so write it with the one
            // member it needs. Deeper paths are not needed and not supported.
            guard rest.count == 1, let leaf = rest.first else { return false }
            insert(
                member: "\"\(escaped(name))\": { \"\(escaped(leaf))\": \"\(escaped(value))\" }",
                into: object, after: existing, to: &characters
            )
            return true
        }

        guard characters[member.valueStart] == "{",
              let inner = objectRange(in: characters, from: member.valueStart)
        else { return false }
        return apply(value, path: rest, within: inner, to: &characters)
    }

    /// Appends a member to an object, matching how its siblings are laid out.
    private static func insert(
        member text: String, into object: Range, after existing: [Member],
        to characters: inout [Character]
    ) {
        let spansLines = characters[object.open...object.close].contains("\n")

        guard let last = existing.last else {
            // An empty object: `{}` stays on its line, a multi-line one gets a
            // line of its own indented past the brace.
            if spansLines {
                let indent = indentation(ofLineContaining: object.close, in: characters)
                characters.insert(
                    contentsOf: Array("\n\(indent)  \(text)\n\(indent)"),
                    at: object.close
                )
            } else {
                characters.insert(contentsOf: Array(text), at: object.close)
            }
            return
        }

        if spansLines {
            let indent = indentation(ofLineContaining: last.nameStart, in: characters)
            characters.insert(contentsOf: Array(",\n\(indent)\(text)"), at: last.valueEnd + 1)
        } else {
            characters.insert(contentsOf: Array(", \(text)"), at: last.valueEnd + 1)
        }
    }

    /// The whitespace that opens the line `index` sits on, so an inserted
    /// member lines up with the ones already there whatever they use.
    private static func indentation(ofLineContaining index: Int, in characters: [Character]) -> String {
        var start = index
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var end = start
        while end < characters.count, characters[end] == " " || characters[end] == "\t" {
            end += 1
        }
        return String(characters[start..<end])
    }
}
