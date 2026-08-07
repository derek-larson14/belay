#!/bin/bash
# audit-log.sh — PostToolUse hook that logs tool usage to JSONL
#
# Appends one JSON line per tool invocation. Truncates long inputs.
# Register as PostToolUse hook on * (all tools).
#
# Config sources (in priority order):
#   1. BELAY_AUDIT_PATH env var
#   2. [audit-log] path in .belay.toml / ~/.belay/config.toml
#   3. Default: ~/.belay/audit.jsonl

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/core/config.sh"

# --- Resolve log path ---
LOG_PATH="${BELAY_AUDIT_PATH:-$(belay_config "audit-log" "path" "$(belay_home)/audit.jsonl")}"

# Expand ~ to $HOME (for user-provided paths in toml or env var)
LOG_PATH="${LOG_PATH/#\~\//$HOME/}"

# Make path absolute if relative
if [[ "$LOG_PATH" != /* ]]; then
  LOG_PATH="$(belay_home)/$LOG_PATH"
fi

# Create directory if needed
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null

# --- Extract fields ---
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CWD=$(pwd)

# Truncate long inputs (> 200 chars)
if [ ${#TOOL_INPUT} -gt 200 ]; then
  INPUT_SUMMARY="${TOOL_INPUT:0:200}..."
else
  INPUT_SUMMARY="$TOOL_INPUT"
fi

# --- Append to log ---
jq -n -c \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg tool "$TOOL_NAME" \
  --arg input "$INPUT_SUMMARY" \
  --arg cwd "$CWD" \
  '{timestamp: $ts, session_id: $sid, tool: $tool, input: $input, cwd: $cwd}' \
  >> "$LOG_PATH" 2>/dev/null

exit 0
