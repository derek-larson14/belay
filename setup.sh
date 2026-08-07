#!/bin/bash
# setup.sh — non-interactive installer for Belay
#
# Called by the /belay:setup command (setup.md).
# All user interaction happens through Claude's AskUserQuestion tool.
# This script takes flags to configure what gets installed.
#
# Usage: ./setup.sh [options]
#   --install-dir DIR       Install location (default: ~/.belay)
#   --settings-file FILE    Settings file to add hooks to
#   --scope global|project  Where to register hooks (default: global)
#   --merge|--replace|--skip  How to handle existing hooks
#   --deny-list             Add recommended deny list
#   --sqlite-deny           Add sqlite3 to deny list
#   --env-project-allowed   Allow project .env files (scope blocking to home dir)
#   --block-osascript       Block osascript in network-guard
#   --allow-persistence     Allow LaunchAgents/crontab management
#   --skip-tests            Skip test suite

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.belay"
SETTINGS_FILE=""
SCOPE="global"
HOOK_MODE="merge"
ADD_DENY_LIST=false
ADD_SQLITE_DENY=false
ENV_PROJECT_ALLOWED=false
BLOCK_OSASCRIPT=false
ALLOW_PERSISTENCE=false
SKIP_TESTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --settings-file) SETTINGS_FILE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --merge) HOOK_MODE="merge"; shift ;;
    --replace) HOOK_MODE="replace"; shift ;;
    --skip) HOOK_MODE="skip"; shift ;;
    --deny-list) ADD_DENY_LIST=true; shift ;;
    --sqlite-deny) ADD_SQLITE_DENY=true; shift ;;
    --env-project-allowed) ENV_PROJECT_ALLOWED=true; shift ;;
    --block-osascript) BLOCK_OSASCRIPT=true; shift ;;
    --allow-persistence) ALLOW_PERSISTENCE=true; shift ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Expand ~ if present
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

# Resolve settings file
if [ -z "$SETTINGS_FILE" ]; then
  if [ "$SCOPE" = "project" ]; then
    SETTINGS_FILE="$(pwd)/.claude/settings.json"
  else
    SETTINGS_FILE="$HOME/.claude/settings.json"
  fi
fi

# --- Copy scripts ---
mkdir -p "$INSTALL_DIR/guards" "$INSTALL_DIR/core"

cp "$SCRIPT_DIR/belay.sh"          "$INSTALL_DIR/"
cp "$SCRIPT_DIR/belay.example.toml" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/audit-log.sh"      "$INSTALL_DIR/"
cp "$SCRIPT_DIR/test-guards.sh"    "$INSTALL_DIR/"
cp "$SCRIPT_DIR/guard-toggle.sh"   "$INSTALL_DIR/"
cp "$SCRIPT_DIR/guards/"*.sh       "$INSTALL_DIR/guards/"
cp "$SCRIPT_DIR/core/"*.sh         "$INSTALL_DIR/core/"

chmod +x "$INSTALL_DIR/belay.sh"
chmod +x "$INSTALL_DIR/audit-log.sh"
chmod +x "$INSTALL_DIR/test-guards.sh"
chmod +x "$INSTALL_DIR/guard-toggle.sh"
chmod +x "$INSTALL_DIR/guards/"*.sh

# Config is user data — seed it once, never clobber it on reinstall.
if [ ! -f "$INSTALL_DIR/config.toml" ]; then
  cp "$SCRIPT_DIR/belay.example.toml" "$INSTALL_DIR/config.toml"
  echo "Created $INSTALL_DIR/config.toml"
else
  echo "Kept existing $INSTALL_DIR/config.toml"
fi

echo "Scripts copied to $INSTALL_DIR"

# --- Apply configuration markers ---
if [ "$ENV_PROJECT_ALLOWED" = true ]; then
  touch "$INSTALL_DIR/.env-project-allowed"
  echo "Created .env-project-allowed marker"
fi

if [ "$BLOCK_OSASCRIPT" = true ]; then
  touch "$INSTALL_DIR/.block-osascript"
  echo "Created .block-osascript marker"
fi

if [ "$ALLOW_PERSISTENCE" = true ]; then
  sed -i '' 's/allow_persistence = false/allow_persistence = true/' "$INSTALL_DIR/config.toml"
  echo "Set allow_persistence = true"
fi

# --- Check for jq ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found."
  echo "Install: brew install jq (macOS) or sudo apt install jq (Ubuntu)"
  exit 1
fi

# --- Build hooks JSON ---
GUARD_CMD="$INSTALL_DIR/belay.sh"
AUDIT_CMD="$INSTALL_DIR/audit-log.sh"

HOOKS_JSON=$(cat <<ENDJSON
{
  "PreToolUse": [
    {
      "matcher": "Bash|Read|Edit|Write|Grep|Glob",
      "hooks": [
        {
          "type": "command",
          "command": "$GUARD_CMD"
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "$AUDIT_CMD"
        }
      ]
    }
  ]
}
ENDJSON
)

# --- Register hooks ---
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ "$HOOK_MODE" = "skip" ]; then
  echo "Skipped hook registration."
elif [ -f "$SETTINGS_FILE" ]; then
  EXISTING=$(cat "$SETTINGS_FILE")
  HAS_HOOKS=$(echo "$EXISTING" | jq 'has("hooks")' 2>/dev/null)

  if [ "$HAS_HOOKS" = "true" ] && [ "$HOOK_MODE" = "replace" ]; then
    MERGED=$(echo "$EXISTING" | jq --argjson hooks "$HOOKS_JSON" '.hooks = $hooks')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    echo "Replaced hooks with Belay config."
  elif [ "$HAS_HOOKS" = "true" ]; then
    # Merge: drop entries we wrote on a previous run (or that an old
    # claude-guard install wrote), then append. A plain append stacks a second
    # dispatcher, and every copy re-runs every guard on every tool call.
    # Only entries pointing into our install dir are removed; a group that also
    # holds a hook of yours keeps that hook.
    MERGED=$(echo "$EXISTING" | jq --argjson hooks "$HOOKS_JSON" --arg dir "$INSTALL_DIR" '
      def is_ours: (.command // "") | startswith($dir + "/") or test("/claude-guard/");
      def strip_ours: [ .[]? | .hooks = [ (.hooks // [])[] | select(is_ours | not) ] | select((.hooks | length) > 0) ];
      .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) | strip_ours) + $hooks.PreToolUse |
      .hooks.PostToolUse = ((.hooks.PostToolUse // []) | strip_ours) + $hooks.PostToolUse
    ')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    echo "Merged Belay hooks into existing config."
  else
    MERGED=$(echo "$EXISTING" | jq --argjson hooks "$HOOKS_JSON" '.hooks = $hooks')
    echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
    echo "Added hooks to existing settings."
  fi
else
  echo "{}" | jq --argjson hooks "$HOOKS_JSON" '{hooks: $hooks}' > "$SETTINGS_FILE"
  echo "Created settings file with hooks."
fi

# --- Deny list ---
# Whatever we add here is recorded in .install-meta.json so `belay uninstall`
# can remove exactly what this install added, and nothing the user wrote.
APPLIED_DENY='[]'

if [ "$ADD_DENY_LIST" = true ]; then
  DENY_RULES='[
    "Bash(security dump-keychain*)",
    "Bash(security find-generic-password*)",
    "Bash(security find-internet-password*)",
    "Bash(security export*)",
    "Bash(pbpaste)",
    "Bash(pbpaste *)",
    "Bash(pbcopy)",
    "Bash(pbcopy *)",
    "Bash(*remote-debugging-port*)",
    "Bash(*remote-debugging-pipe*)",
    "Bash(*remote-debugging-address*)"
  ]'

  if [ "$ADD_SQLITE_DENY" = true ]; then
    DENY_RULES=$(echo "$DENY_RULES" | jq '. + ["Bash(sqlite3 *)"]')
  fi

  CURRENT=$(cat "$SETTINGS_FILE")
  UPDATED=$(echo "$CURRENT" | jq --argjson new_deny "$DENY_RULES" '
    .permissions.deny = ((.permissions.deny // []) + $new_deny | unique)
  ')
  UPDATED=$(echo "$UPDATED" | jq '
    .permissions.allow = ((.permissions.allow // []) | map(
      select(. != "Bash(pbpaste)" and . != "Bash(pbpaste *)" and . != "Bash(pbcopy)" and . != "Bash(pbcopy *)")
    ))
  ')
  echo "$UPDATED" | jq '.' > "$SETTINGS_FILE"
  APPLIED_DENY="$DENY_RULES"
  echo "Applied deny list."
fi

# --- Save metadata ---
HOOKS_BACKUP="$INSTALL_DIR/.hooks-backup.json"
echo "$HOOKS_JSON" | jq '.' > "$HOOKS_BACKUP"

jq -n \
  --arg install_dir "$INSTALL_DIR" \
  --arg settings_file "$SETTINGS_FILE" \
  --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson deny_rules "$APPLIED_DENY" \
  '{install_dir: $install_dir, settings_file: $settings_file,
    installed_at: $installed_at, deny_rules: $deny_rules}' \
  > "$INSTALL_DIR/.install-meta.json"

# --- Tests ---
if [ "$SKIP_TESTS" = false ]; then
  echo ""
  echo "--- Running tests ---"
  "$INSTALL_DIR/test-guards.sh"
  TEST_EXIT=$?
  if [ $TEST_EXIT -ne 0 ]; then
    echo "Some tests failed. Check the output above."
    exit $TEST_EXIT
  fi
fi

echo ""
echo "Belay installed successfully."
echo "  Install dir: $INSTALL_DIR"
echo "  Settings: $SETTINGS_FILE"
