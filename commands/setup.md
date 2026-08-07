---
description: Set up Belay — interactive first-time configuration
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion, Edit, Write
---

# Belay Setup

**Claude Code only.** macOS and Linux.

Interactive setup. All questions go through AskUserQuestion. The actual installation is done by setup.sh with flags.

## Finding Guard Scripts

Look for belay.sh in this order:
1. Plugin cache: `find ~/.claude/plugins/cache -path "*/belay/*/belay.sh" | head -1`
2. Local repo: search `~/Github/belay/`, `~/Projects/belay/`, `~/code/belay/`

Set `GUARD_DIR` to the directory containing the found script.

If not found anywhere, tell the user to install the plugin:
```
/plugin marketplace add derek-larson14/belay
/plugin install belay@belay
```
Then try `/belay:setup` again.

## Step 1: Check existing hooks

Read `~/.claude/settings.json`. Check if `hooks.PreToolUse` contains an entry matching `belay`.

If hooks are already registered, tell the user and skip to the questions.

If not registered, use AskUserQuestion:
"Where should Belay hooks be registered?"
- Global (~/.claude/settings.json) — applies to all projects
- Project (.claude/settings.json) — only this project

Remember the answer as `--scope global` or `--scope project`.

If hooks already exist in the file, use AskUserQuestion:
"Your settings file already has hooks. How should we add Belay?"
- Merge (append alongside existing hooks)
- Replace (overwrite existing hooks)
- Skip (don't touch hooks)

Remember as `--merge`, `--replace`, or `--skip`.

## Step 2: Configure protections

Ask these one at a time using AskUserQuestion. Collect flags for setup.sh.

**Question 1:** "Do you use SQLite in your projects? (If no, we'll block sqlite3 to protect browser databases and password vaults)"
- Yes → no flag
- No → add `--sqlite-deny`

**Question 2:** "Does your project have .env files Claude should be able to read? (If yes, we'll only block .env in your home directory)"
- Yes → add `--env-project-allowed`
- No → no flag

**Question 3:** "Do you use AppleScript/osascript for automation (Reminders, Calendar, Finder, etc.)?"
- Yes → no flag
- No → add `--block-osascript`

**Question 4:** "Do you manage LaunchAgents or crontab through Claude?"
- Yes → add `--allow-persistence`
- No → no flag

## Step 3: Run setup.sh

Build the command from collected flags and run it:
```bash
$GUARD_DIR/setup.sh --deny-list [collected flags]
```

Always include `--deny-list`. Example with all flags:
```bash
$GUARD_DIR/setup.sh --deny-list --sqlite-deny --env-project-allowed --block-osascript --allow-persistence --scope global
```

## Step 4: Summary

Report what setup.sh output. Mention `/belay:configure` to change settings later.
