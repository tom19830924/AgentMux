import Foundation

struct Choice {
    let value: String
    let label: String
    var hint: String?

    init(value: String, label: String, hint: String? = nil) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

/// The questions the add wizard asks, behind a protocol so the flow can be
/// driven by a script in tests instead of a terminal.
protocol Prompter {
    func intro(_ message: String)
    func outro(_ message: String)
    func select(_ message: String, _ choices: [Choice], initial: String?) throws -> String
    func text(_ message: String, placeholder: String?, defaultValue: String?,
              validate: ((String) -> String?)?) throws -> String
    func password(_ message: String) throws -> String
}

extension Prompter {
    func select(_ message: String, _ choices: [Choice]) throws -> String {
        try select(message, choices, initial: nil)
    }

    func text(_ message: String, placeholder: String? = nil, defaultValue: String? = nil,
              validate: ((String) -> String?)? = nil) throws -> String {
        try text(message, placeholder: placeholder, defaultValue: defaultValue, validate: validate)
    }
}

struct TerminalPrompter: Prompter {
    func intro(_ message: String) {
        Terminal.write("\(ansi.cyan("┌"))  \(ansi.bold(message))\n\(ansi.cyan("│"))\n")
    }

    func outro(_ message: String) {
        Terminal.write("\(ansi.cyan("└"))  \(message)\n")
    }

    func select(_ message: String, _ choices: [Choice], initial: String?) throws -> String {
        guard !choices.isEmpty else { throw AgentMuxError("沒有可選的項目") }
        var index = choices.firstIndex { $0.value == initial } ?? 0

        Terminal.write("\(ansi.cyan("◆"))  \(message)\n")
        Terminal.write(ansi.hideCursor)
        render(choices, selected: index, first: true)

        let chosen: String? = Terminal.withRawMode {
            while true {
                switch Terminal.readKey() {
                case .up:
                    index = (index - 1 + choices.count) % choices.count
                    render(choices, selected: index, first: false)
                case .down:
                    index = (index + 1) % choices.count
                    render(choices, selected: index, first: false)
                case .character("k"):
                    index = (index - 1 + choices.count) % choices.count
                    render(choices, selected: index, first: false)
                case .character("j"):
                    index = (index + 1) % choices.count
                    render(choices, selected: index, first: false)
                case .enter:
                    return choices[index].value
                case .cancel:
                    return nil
                default:
                    continue
                }
            }
        }

        guard let chosen else { throw CancelledError() }
        // Collapse the menu to a single line showing what was picked.
        Terminal.write(ansi.up(choices.count + 1))
        for _ in 0...choices.count { Terminal.write(ansi.clearLine + "\n") }
        Terminal.write(ansi.up(choices.count + 1))
        Terminal.write("\(ansi.green("✔"))  \(message) \(ansi.dim("·")) \(choices[index].label)\n")
        return chosen
    }

    private func render(_ choices: [Choice], selected: Int, first: Bool) {
        if !first { Terminal.write(ansi.up(choices.count)) }
        for (offset, choice) in choices.enumerated() {
            let marker = offset == selected ? ansi.cyan("❯") : " "
            let label = offset == selected ? ansi.bold(choice.label) : choice.label
            let hint = choice.hint.map { " \(ansi.dim($0))" } ?? ""
            Terminal.write("\(ansi.clearLine)\(marker) \(label)\(hint)\n")
        }
    }

    func text(_ message: String, placeholder: String?, defaultValue: String?,
              validate: ((String) -> String?)?) throws -> String
    {
        while true {
            let suffix = placeholder.map { " \(ansi.dim("(\($0))"))" } ?? ""
            Terminal.write("\(ansi.cyan("◆"))  \(message)\(suffix)\n\(ansi.cyan("│"))  ")
            guard let line = readLine(strippingNewline: true) else { throw CancelledError() }

            let value = line.isEmpty ? (defaultValue ?? "") : line
            if let problem = validate?(value) {
                Terminal.write("\(ansi.red("▲"))  \(problem)\n")
                continue
            }
            return value
        }
    }

    func password(_ message: String) throws -> String {
        while true {
            Terminal.write("\(ansi.cyan("◆"))  \(message)\n\(ansi.cyan("│"))  ")
            let line = Terminal.withoutEcho { readLine(strippingNewline: true) }
            Terminal.write("\n")
            guard let line else { throw CancelledError() }
            if line.isEmpty {
                Terminal.write("\(ansi.red("▲"))  這一項必填\n")
                continue
            }
            return line
        }
    }
}
