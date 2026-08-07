#!/bin/bash
# workspace-guard.sh — scopes file access to project directory
#
# Resolves file_path via realpath and checks it starts with an allowed root.
# Applies to Read, Write, Edit, Glob, Grep (NOT Bash, since you can't
# reliably parse all path references in shell commands).
#
# Env vars (set by dispatcher):
#   BELAY_ALLOWED_ROOTS: colon-separated list of allowed directories
#                               empty = $CLAUDE_PROJECT_DIR only

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Extract path to check based on tool type
case "$TOOL_NAME" in
  Read|Write|Edit)
    CHECK_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Grep)
    CHECK_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)
    ;;
  Glob)
    CHECK_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac

# If no path specified, allow (tool will use CWD which is the project dir)
[ -z "$CHECK_PATH" ] && exit 0

deny() {
  jq -n \
    --arg reason "$1" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  exit 0
}

# Expand ~ to $HOME
CHECK_PATH="${CHECK_PATH/#\~/$HOME}"

# Resolve symlinks
RESOLVED=$(realpath "$CHECK_PATH" 2>/dev/null || echo "$CHECK_PATH")

# Build allowed roots list
DEFAULT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
ROOTS_STRING="${BELAY_ALLOWED_ROOTS:-$DEFAULT_ROOT}"

# If roots string is empty, use default
[ -z "$ROOTS_STRING" ] && ROOTS_STRING="$DEFAULT_ROOT"

IFS=':' read -ra ROOTS <<< "$ROOTS_STRING"

for root in "${ROOTS[@]}"; do
  [ -z "$root" ] && continue
  # Expand ~ in root too
  root="${root/#\~/$HOME}"
  resolved_root=$(realpath "$root" 2>/dev/null || echo "$root")
  if [[ "$RESOLVED" == "$resolved_root"* ]]; then
    exit 0  # Path is within an allowed root
  fi
done

deny "BLOCKED by workspace-guard: '$CHECK_PATH' is outside the allowed workspace. Allowed roots: ${ROOTS[*]}"
