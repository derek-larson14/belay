---
description: View guard status and change settings
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion, Edit, Write
---

# Belay Configure

**Claude Code only.** macOS and Linux.

View current guard status and change settings interactively.

## Step 1: Find config and show current state

Run `belay status` for current state, then locate the config layer to edit. Display:

```
path-guard:      ON | write-guard: ON | network-guard: OFF (pattern) | workspace-guard: OFF | audit: ON
```

If audit log exists, show last 24h: "X blocks, Y Bash sandboxed, Z total calls"

## Step 2: Ask what to change

Use AskUserQuestion:
"What do you want to change?"
- **Toggle a guard** -- enable or disable a specific guard
- **Change .env policy** -- block / project / allow (dumping contents into the model; processes may always load them)
- **Change network mode** -- switch between sandbox (macOS kernel-level), pattern (cross-platform), or off
- **Set up workspace guard** -- lock file access to specific directories
- **Change audit log path** -- where to write the JSONL log
- **Nothing, just checking** -- exit

For each option, explain what it does before applying:
- **path-guard**: blocks reads to SSH keys, browser cookies, keychains, shell history, messages
- **env_files** (`block` / `project` / `allow`): dumping .env contents into the model. Processes may always load them. `block` denies every dump; `project` allows project .env dumps and still blocks `$HOME/.env`; `allow` turns the check off.
- **write-guard**: blocks writes to LaunchAgents, crontab, shell rc files, SSH authorized_keys
- **network-guard (sandbox)**: kernel-level network blocking on all Bash commands (macOS only, strongest protection)
- **network-guard (pattern)**: blocks weaponized patterns like cookie theft, reverse shells (works on Linux too)
- **workspace-guard**: restricts Read/Write/Edit/Grep/Glob to project directory only (breaks cross-repo work)
- **audit-log**: logs every tool call to JSONL for review

## Step 3: Apply changes

Edit `~/.belay/config.toml` for a global change, or `.belay.toml` at the project root for a project-scoped one. Use AskUserQuestion to let the user choose which scope they want. Never edit files under the plugin cache — those are replaced on update.

## Step 4: Loop or exit

After applying a change, show updated status and ask if they want to change anything else. Loop until they're done.
