# AgentMux

Keep several AI agent gateways per project and pick one at launch, without
touching the settings files the agents already use.

```console
$ claude          # unchanged; works exactly as before
$ am claude       # pick a gateway from the menu first
```

A macOS CLI written in Swift, with no external dependencies.

## What happens when you type `am claude`

It reads `.agentmux/gateways.json`, lists this project's gateways, and once you
pick one it **becomes** `claude` — this process turns into the agent, so Ctrl-C,
the exit status and the terminal are the agent's, with no `am` in the middle.
The choice is injected from above the files the agents read:

| Agent | Mechanism | Overrides |
|---|---|---|
| Claude Code | `--settings` + `apiKeyHelper` | `.claude/settings.json` |
| Codex CLI | `-c` overrides | `~/.codex/config.toml` |

Running `claude` or `codex` directly behaves exactly as it did before.

## Install

```console
$ brew tap tom19830924/tap
$ brew trust tom19830924/tap     # Homebrew asks this of every third-party tap
$ brew install am
```

Update with `brew update && brew upgrade am` — without `brew update` the tap is
never pulled. To build it yourself, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Using it

```console
$ am init                       # create .agentmux/ and walk through the setup
$ am add                        # add a gateway, or another agent to one you have
$ am ls                         # list this project's gateways
$ am claude                     # pick from the menu, then straight into Claude Code
$ am -g my-gateway claude       # name the gateway and skip the menu
$ am claude --resume <id>       # the agent's own arguments, handed over untouched
$ am codex resume <id>          # codex spells the same thing as a subcommand
$ am --dry-run claude           # print what would be injected, without starting
$ am extension                  # put a gateway where the VS Code extension reads it
```

**The agent's name ends am's own arguments.** Everything after it is handed over
untouched, which lets each CLI keep its own spelling without a separator. When
`am add` asks for a base URL it wants the base: each CLI appends its own path,
so copy it from your provider's docs, not from a `curl` example.

## Where your key lives

A key must never reach a command line, because anyone on the machine can read
those out of `ps aux`. So Claude Code is handed an `apiKeyHelper` — a command it
runs only when it needs the key — and Codex an `env_key` naming an environment
variable. The one place a key is stored is `.agentmux/secrets.json`, mode 0600.

A gateway that would put a key into `args` is refused before anything starts.
`am ls` reports only "set" or "missing", `--dry-run` shows a key's name and
never its value, nothing is written outside the project, and no temporary files
are created.

## Seeing which gateway you are on

Set `"statusLine": true` at the top level of `gateways.json` — on or off for the
whole project, off unless asked for — and Claude Code says so until you quit:

```
gateway: my-gateway, key: my-gateway_key, host: api.example.com
```

The key is named, never printed, and only the base URL's host is shown: a status
line ends up in screenshots. A field appears only when there is something to put
in it. The cost: with any custom status line configured, Claude Code stops
printing the footer's keyboard hints. The keys still work.

Codex cannot carry this — its `status_line` only picks and reorders built-in
items, none of which runs a command. Its `/status` panel has a **Model
provider** row, which `am add` names after the gateway, so it answers instead.

## Using it from an editor extension

The VS Code extension never goes through `am`: it starts Claude Code itself and
reads only the project's `.claude/`. `am extension` asks which gateway and key,
then writes them into the git-ignored `.claude/settings.local.json` where the
extension will find them — the key's *name* goes in, the key itself stays in
`.agentmux/secrets.json`.

It touches `apiKeyHelper` and `env.ANTHROPIC_BASE_URL` and nothing else: not
your approvals, permission rules, variables or indentation. Nothing is ever
deleted; switching gateway replaces those two values, and a file it cannot read
as JSON stops the command rather than being overwritten. Picking the gateway
that signs in with Claude Code's own login asks no key and empties
`apiKeyHelper` to `""`, which Claude Code reads as unset — left alone it would
quietly keep winning over the sign-in. The old value is printed.

## Configuration

```
project/
└─ .agentmux/
   ├─ gateways.json   # the gateways; safe to commit (no keys in it)
   ├─ secrets.json    # the keys, 0600
   └─ state.json      # which gateway you picked last
```

Keys are referenced by name and expanded at launch:

```json
{
  "version": 1,
  "statusLine": true,
  "gateways": [
    { "id": "my-gateway", "agents": { "claude": { "settings": {
      "ANTHROPIC_BASE_URL": "https://api.example.com",
      "ANTHROPIC_AUTH_TOKEN": "${secret:my-gateway_key}"
    } } } }
  ]
}
```

No path in these files is absolute, so copying the directory into another
project works. AgentMux never creates or edits a `.gitignore`, and never reads
`.claude/settings.json` or `.codex/config.toml` — those belong to the CLIs,
including the model.

## TODO

- [ ] Put `.claude/` inside `.agentmux/`, symlinked back to the project root.

  Blocked: Claude Code won't write through a symlinked `.claude/`
  ([#27720](https://github.com/anthropics/claude-code/issues/27720)).

- [ ] Show the gateway in Codex's status line.

  Blocked: `status_line` only reorders 26 built-in items; none runs a command.

## License

[MIT](LICENSE)
