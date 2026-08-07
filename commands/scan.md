---
description: Full security audit — hooks, guards, permissions, audit log
allowed-tools: Read, Glob, Grep, Bash
---

# Belay Scan

**Claude Code only.** macOS and Linux.

Perform a full security audit. Find the guard scripts (plugin cache first, then local installs), read config, and report.

## 1. Hook registration

Read `~/.claude/settings.json`. Check `hooks.PreToolUse` and `hooks.PostToolUse`:
- Is belay.sh registered? On which tools?
- Is audit-log.sh registered as PostToolUse?
- Any legacy individual hooks (path-guard.sh registered directly)?

## 2. Guard configuration

Run `belay status` — it reports every guard, its value, and which config layer set it. For each guard, report enabled/disabled and key settings.

## 3. Gap analysis

- Guards that exist as files but aren't enabled in config
- Guards enabled in config but whose script files don't exist
- Hooks registered in settings.json that aren't going through the dispatcher

## 4. Permission analysis

Read `permissions.allow` and `permissions.deny` from `~/.claude/settings.json`:
- Count total Bash allow rules
- Flag rules that reference paths outside the current workspace
- Note any high-risk allows (curl, python, npm, etc.) that network-guard should cover
- Check if recommended deny rules are present

## 5. Audit log summary

If audit-log is enabled, find the log file and summarize the last 24 hours:
- Total tool calls logged
- Tool usage breakdown (top 5)
- Any blocks or interesting patterns

## 6. Credential exposure checks

Scan for common misconfigurations that path-guard doesn't catch at runtime:

**LaunchAgent plist scan** — read all `~/Library/LaunchAgents/*.plist` files and check EnvironmentVariables blocks for token-like patterns: `sk-ant-`, `_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`. Flag any matches with the plist name and key name.

**World-readable log paths** — check StandardOutPath and StandardErrorPath in all plists. Flag any that write to `/tmp/` (world-readable by default).

**Script permissions** — find any `.sh` files executed by LaunchAgents (check ProgramArguments in each plist). Check their permissions. Flag any that are world-readable (644 or 755 — should be 700).

**Stale credential files** — check if these files exist: `~/.anthropic_secrets`, `~/.anthropic_api_key`, `~/.openai_key`. Flag any that are present.

## 7. Report

```
## Belay Security Report

### Guard Status
  path-guard:      [ON/OFF] -- blocks reads to credentials, messages, browser sessions
  write-guard:     [ON/OFF] -- blocks writes to LaunchAgents, shell rc, SSH
  network-guard:   [ON/OFF] (mode: sandbox|pattern|off) -- network restrictions on Bash
  workspace-guard: [ON/OFF] -- scopes file access to project dir
  audit-log:       [ON/OFF] -- logging to [path]

### Hook Registration
  PreToolUse:  [what's registered, on which tools]
  PostToolUse: [what's registered]

### Issues Found
  [list any gaps, misconfigurations, or recommendations]

### Credential Exposure
  LaunchAgent plists: [X checked, Y flagged]
  World-readable log paths: [list any /tmp/ paths found]
  Script permissions: [OK or list of world-readable scripts]
  Stale credential files: [list any found]

### Permission Stats
  [X] Bash allow rules | [Y] deny rules
  [list any concerns]
```
