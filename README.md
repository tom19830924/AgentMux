# AgentMux

Keep a list of AI agent gateways per project, and pick one from a menu at launch.

```console
$ claude          # unchanged; works exactly as before
$ am claude       # pick a gateway from the menu first
```

A macOS CLI written in Swift, with **no external dependencies**.

## What happens when you type `am claude`

Three things, and then `am` is gone:

1. It reads `.agentmux/gateways.json` and lists this project's gateways
2. You pick one
3. It **becomes** `claude`, carrying that gateway's settings

Step 3 is not "starts a claude": this process turns into claude itself. Ctrl-C, the exit status and control of the terminal are all claude's from then on, with no `am` left in the middle to get in the way.

The key is not carried on the command line, where `ps` could read it. What goes across is a line saying "ask me when you need the key", and claude comes back for it only when it actually does.

## Why it exists

A project has one `.claude/settings.json`, which can express one set of settings — there is no way to say "this project can use A, B or C, pick one each time". AgentMux keeps the list in `.agentmux/gateways.json` and injects a choice at launch.

**It rewrites none of your existing settings files.** It overrides them for one launch, from a layer above:

| Agent | Mechanism | Overrides |
|---|---|---|
| Claude Code | `--settings` + `apiKeyHelper` | `.claude/settings.json` |
| Codex CLI | `-c` overrides | `~/.codex/config.toml`, a project's `.codex/config.toml` |

So running `claude` or `codex` directly behaves exactly as it did before you installed this.

## Install

### Homebrew

```console
$ brew tap tom19830924/tap
$ brew trust tom19830924/tap
$ brew install am
```

The middle line is what Homebrew asks of every third-party tap: a formula is Ruby that will be executed, so you have to say so explicitly. Once done, anything else from this tap installs without asking again.

To update:

```console
$ brew update && brew upgrade am
```

`brew update` is what pulls the tap itself; without it `upgrade` cannot see a new version.

### From source

```console
$ git clone https://github.com/tom19830924/AgentMux.git
$ cd AgentMux
$ swift build -c release        # produces .build/release/am
$ swift test
```

Needs Xcode 16 or later (`Package.swift` is swift-tools-version 6.0). Opening `Package.swift` in Xcode works too.

To put it on your PATH:

```console
$ install -m 755 .build/release/am /usr/local/bin/am
```

What comes out is a single executable. macOS ships the Swift runtime, so copying it to another Mac is enough — nothing to install.

For the same universal binary the releases ship:

```console
$ swift build -c release --arch arm64 --arch x86_64
```

A binary you built yourself reports `am --version` as `dev`. The version is written during the release only: a local build is not a release and does not claim to be one.

## Using it

```console
$ am init                   # create .agentmux/ and walk through the setup
$ am add                    # add a gateway, or another agent to one you have
$ am ls                     # list this project's gateways
$ am claude                 # pick from the menu, then straight into Claude Code
$ am claude -g my-gateway   # name the gateway and skip the menu
$ am codex -- --resume      # everything after -- is handed to codex untouched
$ am claude --dry-run       # print what would be injected, without starting
```

## The config files

```
project/
└─ .agentmux/
   ├─ gateways.json   # the gateways; safe to commit (no keys in it)
   ├─ secrets.json    # the keys, 0600
   └─ state.json      # which gateway you picked last
```

Nothing in them is an absolute path, so copying the directory to another project just works.

AgentMux **never creates or edits a `.gitignore`** — whether to ignore `.agentmux/` is the project's decision. It holds keys in the clear, so usually it should be ignored.

`am init` and `am add` ask what they need and write the file for you. Use `${secret:NAME}` to reference a key from `secrets.json`; it is expanded at launch and nowhere else:

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
            "-c", "model_providers.my-gateway.base_url=\"https://api.example.com\"",
            "-c", "model_providers.my-gateway.env_key=\"AGENTMUX_CODEX_KEY\"",
            "-c", "model_provider=\"my-gateway\""
          ],
          "env": { "AGENTMUX_CODEX_KEY": "${secret:my-gateway_key}" }
        }
      }
    }
  ]
}
```

## One key, several agents

The usual case is one provider's token serving both Claude and Codex. Set up the first, then:

```console
$ am add
? Which agent?                          Codex CLI
? Connect to what?                      A third-party gateway
? Add Codex CLI to which gateway?       my-gateway (has claude)
? Base URL                              https://api.example.com/v1
? API shape                             chat
? Which key?                            Reuse my-gateway_key ← already selected; no repaste
```

For a different provider, choose "Enter a new key" and it is stored under its own name; the two never interfere.

Choosing the agent's own login needs neither a name nor an endpoint — it is always called `anthropic` or `openai`, and it only sets the base URL and token to empty strings, cancelling whatever the project pinned so the CLI falls back to its own login.

Neither `am init` nor `am add` reads `.claude/settings.json` or `.codex/config.toml`. Those belong to the CLIs; AgentMux only manages its own files.

## How the key is protected

- **It never lands on disk for a launch, and never reaches a command line.** Anyone can read a command line out of `ps aux`, so neither agent gets the key that way:
  - **Claude**: the JSON passed to `--settings` sets `ANTHROPIC_AUTH_TOKEN` to an empty string, which cancels whatever `.claude/settings.json` holds, and names an `apiKeyHelper` command. Claude Code runs it only when it needs a key; the value comes back through a pipe and is written nowhere.
  - **Codex**: `env_key` names an environment variable, so the key exists only in the launched process's environment.
- The one place a key is stored is `.agentmux/secrets.json`, mode 0600.
- **Nothing is written outside the project at runtime**, and no temporary files are created.
- A gateway that would put a key into `args` is refused before anything starts.
- `am ls` reports only "set" or "missing", and `--dry-run` shows a key's name, never its value.

## Releasing

Push a tag starting with `v`; the rest happens on its own:

```console
$ git tag v0.1.3
$ git push origin v0.1.3
```

GitHub Actions takes it from there:

1. Writes the tag's version into `Sources/am/Version.swift`
2. Runs the tests
3. Builds the universal binary (arm64 + x86_64)
4. Creates the GitHub Release with `am-<version>-macos-universal.tar.gz`
5. Computes the sha256, regenerates `Formula/am.rb` in `tom19830924/homebrew-tap`, and pushes it

Users get it with `brew update && brew upgrade am`.

### One place decides the version

`Version.swift` holds the placeholder `dev`. The real version exists only as a git tag and is written in just before the build, so a published binary cannot disagree with the tag it was published under — not because something checks, but because only one number is ever in play.

If the write matches nothing, or the built binary reports a version other than the tag, the workflow stops and nothing is published.

### Rehearse without publishing

The **Release** workflow has a Run workflow button. Give it a version, leave "Build and package only" ticked, and it runs the tests and the build without touching the Release or the tap, leaving the result downloadable as an artifact.

Use a tag for a real release, so the version stays tied to a commit.

### For whoever maintains this

- The `Tests` workflow runs on every push, so a break shows up long before a release
- `Formula/am.rb` is generated by CI; don't hand-edit `homebrew-tap`
- CI pushes the formula with the `TAP_WRITER` repo secret: a fine-grained token scoped to `homebrew-tap` alone, with write access to contents and nothing else. When it expires, a release stops at "Check out the tap" — the Release still appears, but the formula quietly stays on the old version

## Implementation note

`am claude` does not spawn a child. Once it has a gateway and the environment is set, it `execvp`s and **replaces itself** with the agent. The exit status, Ctrl-C and control of the terminal all pass to the operating system's new occupant of that process: there is nothing left to forward, and no way for `am` to outlive the agent.
