#!/bin/bash
# network-guard.sh — sandboxes Bash commands (network + file writes)
#
# Network modes:
#   sandbox (macOS): wraps Bash commands in sandbox-exec to block ALL outbound
#                    at kernel level. curl, python, compiled binaries, everything.
#   pattern (cross-platform): regex blocklist for weaponized network patterns
#   off: no network restrictions (pattern checks still run as defense-in-depth)
#
# File write sandbox (macOS, requires sandbox-exec):
#   Kernel-level restriction on which directories Bash can write to.
#   Covers all child processes (python, node, compiled binaries, etc.).
#   Works independently of network mode — if deny-write paths are set,
#   sandbox-exec is used even when network mode is "off" or "pattern".
#
# Env vars (set by dispatcher):
#   BELAY_NETWORK_MODE: "sandbox" | "pattern" | "off"
#   BELAY_SANDBOX_DENY_WRITE: colon-separated paths to block writes to
#   BELAY_SANDBOX_ALLOW_WRITE: colon-separated exceptions within denied paths

. "$(cd "$(dirname "$0")/.." && pwd)/core/config.sh"

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only applies to Bash
[ "$TOOL_NAME" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

MODE="${BELAY_NETWORK_MODE:-sandbox}"

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

# === PATTERN CHECKS ===
# These run in ALL modes (including sandbox) as defense-in-depth.
# Patterns that are dangerous enough to block outright, not just sandbox.

# curl sending cookies (session hijacking)
if echo "$COMMAND" | grep -qE 'curl\s+.*(-b|--cookie)\s'; then
  deny "BLOCKED by network-guard: 'curl -b/--cookie' sends browser cookies, enabling session hijacking."
fi

# Reverse shell tools
if echo "$COMMAND" | grep -qE '\b(nc|ncat|netcat)\b'; then
  deny "BLOCKED by network-guard: netcat detected. Common reverse shell tool."
fi

# SSH with key file (exfiltrating stolen keys)
if echo "$COMMAND" | grep -qE 'ssh\s+.*-i\s'; then
  deny "BLOCKED by network-guard: 'ssh -i' uses a key file. Possible credential exfiltration."
fi

# Python HTTP server (data exfiltration endpoint)
if echo "$COMMAND" | grep -qE 'python3?\s+.*-m\s+(http\.server|SimpleHTTPServer)'; then
  deny "BLOCKED by network-guard: Python HTTP server can serve as a data exfiltration endpoint."
fi

# osascript — only blocked if user opted out during setup
# (The .block-osascript marker is created by setup.sh when user says no to AppleScript)
# When network sandbox is on, any network calls osascript spawns are already blocked at kernel level.
GUARD_DIR="${BELAY_INSTALL_DIR:-$(belay_home)}"
if [ -f "$GUARD_DIR/.block-osascript" ]; then
  if echo "$COMMAND" | grep -qE '\bosascript\b'; then
    deny "BLOCKED by network-guard: osascript blocked per setup preferences. Remove ~/.belay/.block-osascript to allow."
  fi
fi

# scp/rsync to remote host (data exfiltration)
if echo "$COMMAND" | grep -qE '\b(scp|rsync)\b.*:'; then
  deny "BLOCKED by network-guard: scp/rsync to remote host detected. Possible data exfiltration."
fi

# === SANDBOX (macOS only) ===
# Activated when network mode is "sandbox" OR file write restrictions are set.
DENY_WRITE="${BELAY_SANDBOX_DENY_WRITE:-}"
ALLOW_WRITE="${BELAY_SANDBOX_ALLOW_WRITE:-}"

USE_SANDBOX=false
[ "$MODE" = "sandbox" ] && USE_SANDBOX=true
[ -n "$DENY_WRITE" ] && USE_SANDBOX=true

# If no sandbox needed, pattern checks above are all we do
if [ "$USE_SANDBOX" = false ]; then
  exit 0
fi

# Check if sandbox-exec is available (macOS only)
if ! command -v sandbox-exec >/dev/null 2>&1; then
  # On Linux, fall back to pattern mode (already checked above)
  exit 0
fi

# Build sandbox profile
SANDBOX_PROFILE='(version 1)(allow default)'

# Network sandbox
if [ "$MODE" = "sandbox" ]; then
  SANDBOX_PROFILE+='(deny network*)'
fi

# File write sandbox — deny writes to specified paths, with exceptions.
# Uses "subpath" for directories, "literal" for individual files.
if [ -n "$DENY_WRITE" ]; then
  IFS=':' read -ra DENY_PATHS <<< "$DENY_WRITE"
  for path in "${DENY_PATHS[@]}"; do
    [ -z "$path" ] && continue
    resolved=$(realpath "$path" 2>/dev/null || echo "$path")
    if [ -f "$resolved" ]; then
      SANDBOX_PROFILE+="(deny file-write* (literal \"$resolved\"))"
    else
      SANDBOX_PROFILE+="(deny file-write* (subpath \"$resolved\"))"
    fi
  done
fi

if [ -n "$ALLOW_WRITE" ]; then
  IFS=':' read -ra ALLOW_PATHS <<< "$ALLOW_WRITE"
  for path in "${ALLOW_PATHS[@]}"; do
    [ -z "$path" ] && continue
    resolved=$(realpath "$path" 2>/dev/null || echo "$path")
    if [ -f "$resolved" ]; then
      SANDBOX_PROFILE+="(allow file-write* (literal \"$resolved\"))"
    else
      SANDBOX_PROFILE+="(allow file-write* (subpath \"$resolved\"))"
    fi
  done
fi

# Wrap the command in sandbox-exec.
# Uses jq @sh for proper shell quoting of the original command.
jq -n \
  --arg cmd "$COMMAND" \
  --arg profile "$SANDBOX_PROFILE" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: {
        command: ("sandbox-exec -p \u0027" + $profile + "\u0027 /bin/bash -c " + ($cmd | @sh))
      }
    }
  }'
exit 0
