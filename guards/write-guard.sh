#!/bin/bash
# write-guard.sh — PreToolUse hook that blocks writes to dangerous locations
#
# Prevents the agent from writing to persistence locations (LaunchAgents,
# cron, systemd), shell rc files, SSH authorized_keys, system config,
# and other paths that could be used for privilege escalation or backdoors.

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Extract the relevant string to check
case "$TOOL_NAME" in
  Write|Edit)
    CHECK_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Bash)
    CHECK_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac

HOME_DIR="$HOME"
ALLOW_PERSISTENCE="${BELAY_ALLOW_PERSISTENCE:-off}"

# Same home-relative normalization as path-guard: the blocked list is absolute,
# but `~/.zshrc` and `$HOME/.zshrc` are how agents actually write it.
for _v in CHECK_PATH CHECK_CMD; do
  _s="${!_v:-}"
  [ -z "$_s" ] && continue
  _s="${_s//\$\{HOME\}/$HOME}"
  _s="${_s//\$HOME/$HOME}"
  _s="${_s//\~\//$HOME/}"
  printf -v "$_v" '%s' "$_s"
done
unset _v _s

# === BLOCKED WRITE LOCATIONS ===
BLOCKED_WRITE_PATHS=(
  # --- Shell startup files ---
  # An agent that writes to these can inject code that runs every time
  # you open a terminal
  "$HOME_DIR/.zshrc"
  "$HOME_DIR/.bashrc"
  "$HOME_DIR/.zprofile"
  "$HOME_DIR/.bash_profile"
  "$HOME_DIR/.profile"
  "$HOME_DIR/.zshenv"
  "$HOME_DIR/.zlogout"
  "$HOME_DIR/.bash_logout"

  # --- Remote access ---
  # authorized_keys = who can SSH into your machine
  # config = SSH connection settings (ProxyCommand can run code)
  "$HOME_DIR/.ssh/authorized_keys"
  "$HOME_DIR/.ssh/config"

  # --- Automation / scripting (macOS) ---
  "$HOME_DIR/Library/Application Scripts"

  # --- System config ---
  "/etc/"
)

# --- Persistence mechanisms (toggle with allow_persistence) ---
# LaunchAgents, LaunchDaemons, systemd, autostart.
# Power users who manage scheduled tasks through Claude can set
# allow_persistence = true in belay.toml or
# BELAY_ALLOW_PERSISTENCE=on in their environment.
if [ "$ALLOW_PERSISTENCE" != "on" ] && [ "$ALLOW_PERSISTENCE" != "true" ]; then
  BLOCKED_WRITE_PATHS+=(
    # macOS
    "$HOME_DIR/Library/LaunchAgents"
    "$HOME_DIR/Library/LaunchDaemons"
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    # Linux
    "$HOME_DIR/.config/systemd"
    "$HOME_DIR/.config/autostart"
  )
fi

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

# --- Check Write/Edit file paths ---
if [ -n "$CHECK_PATH" ]; then
  # Resolve symlinks to catch indirect access
  RESOLVED=$(realpath "$CHECK_PATH" 2>/dev/null || echo "$CHECK_PATH")

  for pattern in "${BLOCKED_WRITE_PATHS[@]}"; do
    if echo "$RESOLVED" | grep -qF "$pattern"; then
      deny "BLOCKED: write to protected path matching '$pattern'. This location can be used for persistence, privilege escalation, or backdoors."
    fi
    # Also check the unresolved path
    if echo "$CHECK_PATH" | grep -qF "$pattern"; then
      deny "BLOCKED: write to protected path matching '$pattern'. This location can be used for persistence, privilege escalation, or backdoors."
    fi
  done
fi

# --- Check Bash commands for write operations to blocked paths ---
if [ -n "$CHECK_CMD" ]; then
  # Check for output redirection or write commands targeting blocked paths
  for pattern in "${BLOCKED_WRITE_PATHS[@]}"; do
    # Catch: echo/cat/tee/cp/mv/install writing to blocked paths
    if echo "$CHECK_CMD" | grep -qF "$pattern"; then
      # Allow read-only commands
      if echo "$CHECK_CMD" | grep -qE "^(cat |head |tail |less |more |wc |file |stat |ls |diff |md5 |shasum |readlink |grep |egrep |fgrep |rg )"; then
        continue
      fi
      deny "BLOCKED: Bash command references protected path '$pattern'. This location is write-protected to prevent persistence/escalation."
    fi
  done

  # Block persistence commands (when not allowed)
  if [ "$ALLOW_PERSISTENCE" != "on" ] && [ "$ALLOW_PERSISTENCE" != "true" ]; then
    # Block crontab modification
    if echo "$CHECK_CMD" | grep -qE "(crontab\s+-[elr]|crontab\s+[^-])"; then
      deny "BLOCKED: crontab modification. Scheduled tasks should be set up by the user, not the agent."
    fi

    # Block launchctl load/bootstrap (macOS: registering new agents)
    if echo "$CHECK_CMD" | grep -qE "launchctl\s+(load|bootstrap|submit)"; then
      deny "BLOCKED: launchctl load/bootstrap. Registering new launch agents requires manual approval."
    fi

    # Block systemctl enable/start for user services (Linux)
    if echo "$CHECK_CMD" | grep -qE "systemctl\s+--user\s+(enable|start)"; then
      deny "BLOCKED: systemctl user service registration. Enabling persistent services requires manual approval."
    fi
  fi
fi

# Allow everything else
exit 0
