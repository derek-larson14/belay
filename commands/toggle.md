---
description: Turn Belay on or off
allowed-tools: Read, Glob, Grep, Bash, Edit, Write
---

# Belay Toggle

**Claude Code only.** macOS and Linux.

Arguments: $ARGUMENTS

Quick on/off for all guards at once by editing hooks in settings.json.

## Determine action

- If argument is "on": turn guards on
- If argument is "off": turn guards off
- If no argument: check current state and flip it

## Turn off

1. Read `~/.claude/settings.json`
2. Find and remove hook entries that reference `belay` from `hooks.PreToolUse` and `hooks.PostToolUse`
3. Save the removed entries to `~/.belay/.hooks-backup.json` (create directory if needed)
4. Write the updated settings file
5. Report: "Guards off. Hooks removed from settings.json. Run `/belay:toggle on` to re-enable."

## Turn on

1. Check if hooks are already registered. If yes, report "Guards are already on" and show status.
2. Look for backup at `~/.belay/.hooks-backup.json`
3. If backup exists, merge those hooks back into settings.json
4. If no backup, find the guard scripts (plugin cache first) and register fresh hooks:
   - PreToolUse: `Bash|Read|Edit|Write|Grep|Glob` -> belay.sh
   - PostToolUse: `*` -> audit-log.sh
5. Write the updated settings file
6. Report: "Guards on." and show one-liner status of each guard.
