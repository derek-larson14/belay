#!/bin/bash
# dispatch.sh — normalize → guards → harness-shaped response
#
# stdin: any harness tool payload (or canonical)
# env:
#   BELAY_ROOT — Belay install root
#   BELAY_HARNESS — claude | pi | grok  (default: claude)
#
# exit codes:
#   0 — allow (or deny for claude/pi expressed in stdout JSON)
#   2 — deny when BELAY_HARNESS=grok (Grok convention)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${BELAY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export BELAY_ROOT="$ROOT"

NORMALIZE="$SCRIPT_DIR/normalize.sh"
# Prefer legacy dispatcher name for guard scripts colocated at root
GUARD="$ROOT/belay.sh"
HARNESS="${BELAY_HARNESS:-claude}"

if [ ! -x "$NORMALIZE" ]; then
  chmod +x "$NORMALIZE" 2>/dev/null || true
fi

RAW=$(cat)
CANON=$("$NORMALIZE" <<<"$RAW")

# Carry the harness's working directory through to the guards. Without it,
# path-guard cannot resolve a relative path, and `cat id_rsa` from inside the
# directory looks like an ordinary file read. Grok sends cwd/workspaceRoot;
# Claude Code sends cwd; fall back to this process's cwd.
SESSION_CWD=$(echo "$RAW" | jq -r '.cwd // .workspaceRoot // empty' 2>/dev/null)
[ -z "$SESSION_CWD" ] && SESSION_CWD="$PWD"

TOOL=$(echo "$CANON" | jq -r '.tool')
if [ "$TOOL" = "other" ] || [ -z "$TOOL" ]; then
  # no policy
  case "$HARNESS" in
    grok) echo '{"decision":"allow"}'; exit 0 ;;
    pi)   exit 0 ;;
    *)    exit 0 ;;
  esac
fi

# Map canonical → Claude Code wire format (what path/write/network guards expect)
GUARD_IN=$(echo "$CANON" | jq -c '
  def claude_tool:
    if .tool == "bash" then "Bash"
    elif .tool == "read" then "Read"
    elif .tool == "write" then "Write"
    elif .tool == "edit" then "Edit"
    elif .tool == "grep" then "Grep"
    elif .tool == "glob" then "Glob"
    else "Unknown" end;
  def claude_input:
    if .tool == "bash" then {command: (.args.command // "")}
    elif .tool == "read" or .tool == "write" or .tool == "edit" then
      {file_path: (.args.path // "")}
      + (if .args.content then {content: .args.content} else {} end)
      + (if .args.old_string then {old_string: .args.old_string} else {} end)
      + (if .args.new_string then {new_string: .args.new_string} else {} end)
    elif .tool == "grep" then {path: (.args.path // "."), pattern: (.args.pattern // "")}
    elif .tool == "glob" then {path: (.args.path // "."), pattern: (.args.pattern // "*")}
    else {} end;
  {tool_name: claude_tool, tool_input: claude_input}
')
GUARD_IN=$(echo "$GUARD_IN" | jq -c --arg cwd "$SESSION_CWD" '. + {cwd: $cwd}')

OUT=$(echo "$GUARD_IN" | "$GUARD" || true)

# --- Parse guard output into action ---
ACTION="allow"
REASON=""
UPDATED=""

if [ -n "$OUT" ]; then
  if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    ACTION="deny"
    REASON=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "Blocked by Belay"')
  elif echo "$OUT" | jq -e '.hookSpecificOutput.updatedInput' >/dev/null 2>&1; then
    ACTION="allow"
    UPDATED=$(echo "$OUT" | jq -c '.hookSpecificOutput.updatedInput')
  elif echo "$OUT" | jq -e '.block == true' >/dev/null 2>&1; then
    ACTION="deny"
    REASON=$(echo "$OUT" | jq -r '.reason // "Blocked by Belay"')
  elif echo "$OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
    ACTION="deny"
    REASON=$(echo "$OUT" | jq -r '.reason // "Blocked by Belay"')
  fi
fi

# --- Emit harness response ---
case "$HARNESS" in
  grok)
    if [ "$ACTION" = "deny" ]; then
      jq -n --arg reason "$REASON" '{decision: "deny", reason: $reason}'
      exit 2
    fi
    # Grok: no command-rewrite API; sandbox wrap is dropped (deny-or-allow only)
    echo '{"decision":"allow"}'
    exit 0
    ;;
  pi)
    if [ "$ACTION" = "deny" ]; then
      jq -n --arg reason "$REASON" '{block: true, reason: $reason}'
      exit 0
    fi
    if [ -n "$UPDATED" ]; then
      # Map file_path → path for Pi if present
      PI_UP=$(echo "$UPDATED" | jq -c '
        if has("file_path") and (has("path") | not) then . + {path: .file_path} | del(.file_path) else . end
      ')
      jq -n --argjson ui "$PI_UP" '{block: false, updatedInput: $ui}'
      exit 0
    fi
    exit 0
    ;;
  claude|*)
    if [ "$ACTION" = "deny" ]; then
      jq -n --arg reason "$REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $reason
        }
      }'
      exit 0
    fi
    if [ -n "$UPDATED" ]; then
      jq -n --argjson ui "$UPDATED" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          updatedInput: $ui
        }
      }'
      exit 0
    fi
    exit 0
    ;;
esac
