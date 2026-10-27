# AgentMux

Keep several AI agent gateways per project and pick one at launch, without
touching the settings files the agents already use.

```console
$ claude          # unchanged; works exactly as before
$ am claude       # pick a gateway from the menu first
```

A macOS CLI written in Swift, with no external dependencies.

## What happens when you type `am claude`

Three things, and then `am` is gone:

1. It reads `.agentmux/gateways.json` and lists this project's gateways
2. You pick one
3. It **becomes** `claude`, carrying that gateway's settings

Step 3 is not "starts a claude": this process turns into claude itself, so
Ctrl-C, the exit status and control of the terminal are claude's from then on,
with no `am` left in the middle.

A project has one `.claude/settings.json`, which can express one set of
settings — there is no way to say "this project can use A, B or C, pick one
each time". AgentMux keeps the list separately and injects a choice at launch,
from a layer above the files the agents read:

| Agent | Mechanism | Overrides |
|---|---|---|
| Claude Code | `--settings` + `apiKeyHelper` | `.claude/settings.json` |
| Codex CLI | `-c` overrides | `~/.codex/config.toml` |

Running `claude` or `codex` directly behaves exactly as it did before.

## Install

```console
$ brew tap tom19830924/tap
$ brew trust tom19830924/tap
$ brew install am
```

The middle line is what Homebrew asks of every third-party tap: a formula is
Ruby that will be executed, so you have to say so explicitly. Update with
`brew update && brew upgrade am` — `brew update` is what pulls the tap, and
without it `upgrade` cannot see a new version.

To build it yourself instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

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
$ am --link claude              # keep .claude/ inside .agentmux/, linked back
$ am --link codex               # the same for .codex/
$ am --unlink claude            # remove the link, keeping what it points at
```

**The agent's name ends am's own arguments.** Everything before it is read by
`am`; everything after it is handed to the agent untouched, whatever it looks
like. That is what lets the two CLIs keep their own spelling — `--resume <id>`
for Claude Code, `resume <id>` for Codex — without a separator in between.

`am init` and `am add` ask what they need and write the files for you. The one
answer worth knowing in advance is the base URL: each CLI appends its own path
to it, so copy the base from your provider's documentation rather than from a
`curl` example that already includes the endpoint.

`--link` puts an agent's own configuration inside `.agentmux/` and links it
back from the project root, so one directory holds the whole setup: gateways,
keys, and whatever `.claude/` or `.codex/` reads. It is the same for both
agents, chooses no gateway, and generates nothing — what those directories
hold is yours to put there. The link itself sits outside `.agentmux/`, so a
copy of that directory in another project needs `--link` run once to attach it.

An existing `.claude/` or `.codex/` is moved across after it asks, keeping a
copy as `.claude_bak` or `.codex_bak`; with nothing there, an empty directory
is created, so whatever the agent writes later lands inside `.agentmux/` too. A
directory in both places at once is refused rather than guessed at, `--unlink`
removes only a link am made itself, and nothing is ever deleted.

## Where your key lives

The whole design is about one thing: a key must never reach a command line,
because anyone on the machine can read those out of `ps aux`.

- **Claude Code** is handed an `apiKeyHelper` — a command it runs only when it
  actually needs a key. The value comes back through a pipe and is written
  nowhere.
- **Codex** gets an `env_key` naming an environment variable, so the key exists
  only in the launched process's environment.
- The one place a key is stored is `.agentmux/secrets.json`, mode 0600.
- A gateway that would put a key into `args` is refused before anything starts.
- `am ls` reports only "set" or "missing", and `--dry-run` shows a key's name,
  never its value.

Nothing is written outside the project at runtime, and no temporary files are
created.

## Configuration

```
project/
├─ .agentmux/
│  ├─ gateways.json   # the gateways; safe to commit (no keys in it)
│  ├─ secrets.json    # the keys, 0600
│  ├─ state.json      # which gateway you picked last
│  └─ .claude/        # only after --link: whatever the agent itself reads
└─ .claude -> .agentmux/.claude      # the link, which lives out here
```

`gateways.json` references keys by name, expanded at launch and nowhere else:

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
        }
      }
    }
  ]
}
```

It is the file worth editing: everything the agents are launched with is
generated from it. Nothing in these files is an absolute path, so copying
the directory to another project works.

AgentMux never creates or edits a `.gitignore`: whether to ignore `.agentmux/`
is the project's decision, and since it holds keys in the clear, usually it
should be. Neither `am init` nor `am add` reads `.claude/settings.json` or
`.codex/config.toml` — those belong to the CLIs, including the model, which
stays wherever you already set it.

## License

[MIT](LICENSE)
