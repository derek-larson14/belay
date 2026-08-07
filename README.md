<p align="center">
  <img src="assets/climber.png" alt="Belay" width="96" />
</p>

<h1 align="center">Belay</h1>

<p align="center">
  <strong>Make your agent's worst day survivable.</strong>
</p>

<p align="center">
  YOLO mode, on belay. Set limits on the agent instead of relying on the<br>
  model's judgment about what's safe. Works with Claude Code, Pi, and Grok Build.
</p>

<p align="center">
  <a href="https://github.com/derek-larson14/belay/stargazers"><img src="https://img.shields.io/github/stars/derek-larson14/belay?style=flat&color=yellow" alt="Stars"></a>
  <a href="#platform-support"><img src="https://img.shields.io/badge/works_with-Claude_Code_·_Pi_·_Grok-orange?style=flat" alt="Works with Claude Code, Pi, Grok Build"></a>
  <a href="https://github.com/derek-larson14/belay/commits/main"><img src="https://img.shields.io/github/last-commit/derek-larson14/belay?style=flat" alt="Last commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/derek-larson14/belay?style=flat" alt="License"></a>
</p>

<p align="center">
  <a href="#why-it-exists">Why</a> ·
  <a href="#install">Install</a> ·
  <a href="#what-it-blocks">What it blocks</a> ·
  <a href="#per-session-overrides">Per-session</a> ·
  <a href="#configuration">Config</a> ·
  <a href="#limitations">Limitations</a>
</p>

```bash
# Skip every permission prompt. It still can't reach the network or leave this repo.
BELAY_NETWORK_MODE=sandbox \
BELAY_WORKSPACE_GUARD=on \
BELAY_ALLOWED_ROOTS="$HOME/Github/my-app" \
BELAY_SANDBOX_DENY_WRITE="$HOME/Github" \
BELAY_SANDBOX_ALLOW_WRITE="$HOME/Github/my-app" \
claude -p "fix the scroll bug" --dangerously-skip-permissions
```

Built by [Derek Larson](https://dtlarson.com). Backstory: [Keys to the Castle](https://dtlarson.com/keys-to-the-castle).

## Why it exists

I wanted Claude Code running without my involvement, next to sensitive data. Claude Code has no way to say "you can touch this folder, but nothing else on the machine." 

**Why not a container or a worktree?** Those isolate the repo, not your credentials — you mount those in yourself, because the work needs a git identity and an npm token. Belay draws the line the other way: the agent keeps your machine and your tools, and loses the parts it has no business in.

## Install

### Claude Code

```
/plugin marketplace add derek-larson14/belay
/plugin install belay@belay
/belay:setup
```

### Pi or Grok Build

```bash
git clone https://github.com/derek-larson14/belay && cd belay
./belay install
./belay status
```

```bash
./belay install pi     # or: claude | grok | all
./belay off pi
```

| Harness | Wires into |
|---------|------------|
| Claude Code | `~/.claude/settings.json` |
| [Pi](https://pi.dev) | `pi install` → `~/.pi/agent/settings.json` |
| Grok Build | `~/.grok/hooks/belay.json` |

## Uninstall

```bash
belay off            # unwire every harness — scripts and config stay put
belay off claude     # or one at a time: claude | pi | grok
```

`belay on` puts it back. To remove it entirely:

```bash
belay uninstall            # unwire everything, drop the deny rules we added
belay uninstall --purge    # also delete ~/.belay (config + audit log)
```

Claude Code plugin users: also `/plugin uninstall belay@belay`.

`on`, `off`, and `uninstall` only touch entries Belay wrote. Other hooks in your `settings.json` stay where they are, including hooks that share a matcher with ours. `uninstall` removes exactly the `permissions.deny` rules `/belay:setup` added — recorded at install time — and leaves your own rules alone.

## How it works

Every tool call goes through four guards. First deny wins.

**Path guard** — blocks sensitive paths (credentials, browser sessions, keychains, clipboard, shell history, …). Categories toggle in config.

**Write guard** — blocks writes to shell rc files, LaunchAgents, SSH `authorized_keys`, and similar.

**Network guard** — `sandbox` (macOS: no network for shell commands), `pattern` (blocks known exfil patterns), or `off`.

**Workspace guard** — optional. File tools only see the project dirs you list.

### Path matching

Catches the usual spellings of sensitive paths, for example:

- `~/.ssh/id_rsa`
- `$HOME/.aws/credentials`
- `cat ~/Library/Messages/chat.db`

### Write sandbox (macOS)

Pick folders the agent may not write to. Optional allow-list for exceptions.

```bash
BELAY_SANDBOX_DENY_WRITE="$HOME/Github/exec" \
BELAY_SANDBOX_ALLOW_WRITE="$HOME/Github/exec/scratch/build" \
claude -p "build the feature" --dangerously-skip-permissions
```

## Per-session overrides

Env vars beat config for that run only.

```bash
BELAY_NETWORK_GUARD=on \
BELAY_NETWORK_MODE=sandbox \
BELAY_WORKSPACE_GUARD=on \
BELAY_ALLOWED_ROOTS="$HOME/Github/my-app:$HOME/Github/my-lib" \
claude -p "fix the scroll bug" --dangerously-skip-permissions
```

```bash
BELAY_NETWORK_GUARD=on
BELAY_PATH_GUARD=off
BELAY_NETWORK_MODE=sandbox
BELAY_ALLOWED_ROOTS="/a:/b"
BELAY_SANDBOX_DENY_WRITE="/protected/path"
BELAY_SANDBOX_ALLOW_WRITE="/protected/path/ok"

# Path guard categories
BELAY_PATH_CAT_CREDENTIALS=off
BELAY_PATH_CAT_CLIPBOARD=off
BELAY_PATH_CAT_BROWSER_SESSIONS=off
# Also: messages, keychains, password-managers,
#   system-data, shell-history, claude-internals, browser-hijacking
```

## Commands

```
belay install [claude|pi|grok|all]
belay status
belay on / off [harness|all]
belay uninstall [--purge]
belay log [N]
belay test
```

Claude Code slash commands:

```
/belay:setup
/belay:scan
/belay:configure
/belay:toggle
```

## What it blocks

**Credentials** — SSH keys, AWS creds, API tokens, .env files, Docker/Kubernetes config

**Browser sessions** — Cookies and local storage for Chrome, Arc, Firefox, Safari, Brave, Edge, Dia

**Password managers** — 1Password vaults, system keychains, GNOME keyring, GPG keys

**Messages and email** — iMessage, Mail, Signal databases

**Clipboard** — pbpaste, pbcopy, xclip, xsel

**Shell history** — .bash_history, .zsh_history, .psql_history, .python_history

**Network** — no network for shell commands on macOS sandbox mode; patterns for cookie theft, reverse shells, scp/rsync

**Writes** — folders you mark off-limits; also persistence targets (LaunchAgents, crontab, shell rc, SSH authorized_keys)

**Browser hijacking** — `--remote-debugging-port`, Puppeteer/Playwright connect, Chrome DevTools Protocol

## Configuration

Highest wins, per key:

```
BELAY_* env  >  <project>/.belay.toml  >  ~/.belay/config.toml  >  defaults
```

A project file that sets one key only overrides that key.

With no config you get path + write guards on; network and workspace are opt-in. `belay status` shows every value and which layer set it.

`belay.example.toml` is the reference. `belay install` copies it to `~/.belay/config.toml` once and never overwrites it.

```toml
[path-guard]
enabled = true

[path-guard.categories]
credentials = true
browser-sessions = true
messages = true
keychains = true
password-managers = true
system-data = true
shell-history = true
claude-internals = true
clipboard = true
browser-hijacking = true

[write-guard]
enabled = true

[network-guard]
enabled = false
mode = "pattern"  # "sandbox" | "pattern" | "off"

[workspace-guard]
enabled = false
allowed_roots = ""

[audit-log]
enabled = true
path = "~/.belay/audit.jsonl"
```

Project override: `.belay.toml` at the project root.

## Audit log

Every tool call goes to `~/.belay/audit.jsonl`: what was touched, when, and whether a guard blocked it.

## Self-protection

Blocks the agent from editing Belay itself, its config, or the harness hook files.

```bash
BELAY_SELF_PROTECT=on claude
```

## Limitations

String matching is imperfect. On macOS, sandbox mode is the strong path.

Workspace guard covers file tools (Read/Write/Edit/Grep/Glob), not the shell. Use `BELAY_SANDBOX_DENY_WRITE` if you need write limits on shell commands.

`sandbox-exec` is macOS only. Linux uses pattern mode for network and has no write sandbox.

## Platform support

| Platform | Status |
|----------|--------|
| macOS | Full |
| Linux | Pattern network guard, no write sandbox. Everything else works. |

## Tests

```bash
cd /path/to/belay
./belay test
./core/test-normalize.sh
./adapters/pi/test-bridge.sh
```

## Contributing

Issues and PRs welcome.

## License

MIT
