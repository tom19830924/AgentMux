import Foundation

let version = "0.2.0"

func helpText() -> String {
    let agents = Agent.allCases
        .map { "  \($0.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.displayName) \(ansi.dim("（\($0.injectionSummary)）"))" }
        .joined(separator: "\n")

    return """
    \(ansi.bold("am")) — 每專案的 AI agent gateway 切換器

    用法：
      am init                     建立 .agentmux/ 並設定第一個 gateway
      am add                      新增一個 gateway，或替既有 gateway 加上另一個 agent
      am ls                       列出這個專案的 gateway
      am secret get <name>        印出一把金鑰（Claude Code 取金鑰時會呼叫）
      am <agent> [選項] [-- ...]  選一個 gateway 並啟動 agent

    agent：
    \(agents)

    選項：
      -g, --gateway <id>   跳過選單，直接用指定的 gateway
          --dry-run        印出實際會注入的內容，不啟動
      -h, --help           顯示這份說明
      -v, --version        顯示版本

    範例：
      am add                      互動式新增，同一把金鑰可以給多個 agent 共用
      am claude                   跳選單，選完直接進 Claude Code
      am claude -g mixroute       指定 gateway
      am codex -- --resume        -- 之後的參數原樣轉給 codex

    直接打 claude 或 codex 不受影響，照原本的設定檔運作。

    """
}

func run(_ argv: [String]) throws -> Int32 {
    // Everything after `--` belongs to the agent and is never interpreted here.
    let separator = argv.firstIndex(of: "--")
    let own = separator.map { Array(argv[..<$0]) } ?? argv
    let passthrough = separator.map { Array(argv[($0 + 1)...]) } ?? []

    guard let first = own.first else {
        Terminal.write(helpText())
        return 0
    }
    let rest = Array(own.dropFirst())

    switch first {
    case "-h", "--help":
        Terminal.write(helpText())
        return 0
    case "-v", "--version":
        Terminal.write("\(version)\n")
        return 0
    case "init":
        return try initCommand()
    case "add":
        return try addCommand()
    case "ls":
        return try listCommand()
    case "secret":
        guard rest.first == "get" else {
            throw AgentMuxError("用法：am secret get <name>", hint: "Claude Code 的 apiKeyHelper 會呼叫它")
        }
        return try secretGetCommand(Array(rest.dropFirst()))
    default:
        break
    }

    guard Agent.isAgent(first) else {
        throw AgentMuxError(
            "不認識的指令 \"\(first)\"",
            hint: "可用的有：init、add、ls、secret，或 agent 名稱"
                + "（\(Agent.allCases.map(\.id).joined(separator: "、"))）"
        )
    }

    var options = RunOptions(passthrough: passthrough)
    var index = 0
    while index < rest.count {
        let argument = rest[index]
        switch argument {
        case "-g", "--gateway":
            guard index + 1 < rest.count else {
                throw AgentMuxError("\(argument) 後面要接 gateway id")
            }
            options.gateway = rest[index + 1]
            index += 2
        case "--dry-run":
            options.dryRun = true
            index += 1
        default:
            if argument.hasPrefix("--gateway=") {
                options.gateway = String(argument.dropFirst("--gateway=".count))
                index += 1
                continue
            }
            throw AgentMuxError(
                "am 不認識選項 \"\(argument)\"",
                hint: "要把參數轉給 \(first) 的話，請放在 -- 後面：am \(first) -- \(argument)"
            )
        }
    }

    return try runCommand(agentId: first, options: options, prompter: TerminalPrompter())
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let error as AgentMuxError {
    FileHandle.standardError.write(Data("\(ansi.red("錯誤")) \(error.message)\n".utf8))
    if let hint = error.hint {
        FileHandle.standardError.write(Data("\(ansi.dim(hint))\n".utf8))
    }
    exit(1)
} catch is CancelledError {
    FileHandle.standardError.write(Data("\(ansi.dim("已取消"))\n".utf8))
    exit(130)
} catch {
    FileHandle.standardError.write(Data("\(ansi.red("錯誤")) \(error)\n".utf8))
    exit(1)
}
