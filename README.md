# AgentMux

每個專案各自管理一組 AI agent gateway，啟動時從選單挑一個。

```console
$ claude          # 原始用法，行為完全不變
$ am claude       # 跳選單選 gateway
```

Swift 寫的 macOS CLI，**零外部依賴**。

## 為什麼需要它

`.claude/settings.json` 一個專案只能有一份，只能表達一組設定 —— 沒辦法「這個專案可用 A、B、C，每次啟動挑一個」。AgentMux 把 gateway 清單放進 `.agentmux/gateways.json`，啟動時才注入。

**它不改寫你任何既有的設定檔**，只在啟動那一瞬間從更高的優先序蓋過去：

| Agent | 機制 | 蓋過 |
|---|---|---|
| Claude Code | `--settings` + `apiKeyHelper` | `.claude/settings.json` |
| Codex CLI | `-c` 覆寫 | `~/.codex/config.toml`、專案 `.codex/config.toml` |

所以直接打 `claude` 或 `codex` 時行為與安裝前完全一致。

## 建置

```console
$ swift build -c release      # 產出 .build/release/am
$ swift test
```

也可以直接用 Xcode 開啟 `Package.swift`。

產出的是單一執行檔，macOS 內建 Swift runtime，複製到別台 Mac 就能跑，不需要安裝任何東西。要怎麼放進 PATH 由你決定。

## 使用

```console
$ am init                   # 建立 .agentmux/ 並走完設定流程
$ am add                    # 新增 gateway，或替既有 gateway 加上另一個 agent
$ am ls                     # 列出這個專案的 gateway
$ am claude                 # 跳選單，選完直接進 Claude Code
$ am claude -g my-gateway     # 指定 gateway，跳過選單
$ am codex -- --resume      # -- 之後的參數原樣轉給 codex
$ am claude --dry-run       # 印出實際會注入什麼，不啟動
```

## 設定檔

```
專案/
└─ .agentmux/
   ├─ gateways.json   # gateway 清單，可 commit（不含金鑰）
   ├─ secrets.json    # 金鑰，0600
   └─ state.json      # 上次選的 gateway
```

裡面沒有任何絕對路徑，整個目錄複製到另一個專案就能直接用。

AgentMux **不會建立或修改任何 `.gitignore`** —— 要不要忽略 `.agentmux/` 由專案自己決定。它含有明文金鑰，所以通常應該忽略掉。

`am init` 與 `am add` 會互動式問完必要資訊並直接寫好。用 `${secret:NAME}` 引用 `secrets.json` 裡的金鑰，啟動時才展開：

```json
{
  "version": 1,
  "gateways": [
    {
      "id": "my-gateway",
      "agents": {
        "claude": {
          "settings": {
            "ANTHROPIC_BASE_URL": "https://api.example.com",
            "ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}"
          }
        },
        "codex": {
          "args": [
            "-c", "model_providers.agentmux.base_url=\"https://api.example.com\"",
            "-c", "model_providers.agentmux.env_key=\"AGENTMUX_CODEX_KEY\"",
            "-c", "model_provider=\"agentmux\""
          ],
          "env": { "AGENTMUX_CODEX_KEY": "${secret:my-gateway_key}" }
        }
      }
    }
  ]
}
```

gateway 只有一個名稱，選單上顯示它、`-g` 也用它（想讓選單顯示別的字，可以手加 `"label"`）。

## 同一把金鑰給多個 agent

常見情況是同一個 provider 的 token 同時要給 Claude 和 Codex 用。先設好其中一個，之後：

```console
$ am add
? 要設定哪個 agent？                   Codex CLI
? 要連到哪裡？                         第三方 gateway
? 要把 Codex CLI 加到哪個 gateway？    my-gateway (已有 claude)
? Base URL                             https://api.example.com/v1
? API 形式                             chat
? 金鑰要用哪一把？                     沿用 my-gateway_key ← 預設就選這個，不用重貼
? 模型（可留空）                       gpt-5.6-luna
```

換成另一家 provider 時選「輸入新的金鑰」，它會存成另一個名稱，兩把互不影響。

選「官方」的話不用取名也不用填端點 —— 它固定叫 `anthropic` / `openai`，只會把 base URL 與 token 設成空字串來中和掉專案的設定，讓 CLI 回到自己原本的登入。

`am init` 與 `am add` 都不會讀取 `.claude/settings.json` 或 `.codex/config.toml` —— 那些是給原本的 CLI 用的，AgentMux 只管自己的設定檔。

## 金鑰怎麼被保護

- **金鑰不落地、也不進命令列。** `ps aux` 任何人都讀得到命令列，所以兩個 agent 都不把金鑰放在那裡：
  - **Claude**：`--settings` 的 JSON 裡 `ANTHROPIC_AUTH_TOKEN` 設成空字串（這會取消掉 `.claude/settings.json` 的值），另外用 `apiKeyHelper` 指定一個取金鑰的指令。Claude Code 需要金鑰時才執行它，值經管線傳回，不寫入任何檔案。
  - **Codex**：`env_key` 指向一個環境變數，金鑰只存在被啟動行程的環境裡。
- 唯一存放金鑰的地方是 `.agentmux/secrets.json`（0600）。
- **執行期不會寫任何東西到專案外**，也不產生暫存檔。
- 若某個 gateway 把金鑰寫進 `args`，啟動前會被擋下並報錯。
- `am ls` 只顯示「已設定 / 缺少」，`--dry-run` 只顯示金鑰名稱。

## 實作筆記

`am claude` 不是衍生子行程，而是用 `execvp` **取代**自己。選完 gateway、設好環境變數之後，這個行程就變成 agent 本身 —— exit code、Ctrl-C、終端機前景控制全部交給作業系統，沒有需要轉發的東西，`am` 也不可能比 agent 活得久。
