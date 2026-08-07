#!/bin/bash
# guard-toggle.sh — enable or disable belay hooks in settings.json
#
# This script is the key UX piece: Claude CANNOT run it because path-guard
# blocks writes to settings.json and the guard scripts. Only humans can
# toggle the guards on and off.
#
# Only Belay's own hook entries are touched. Other PreToolUse/PostToolUse
# hooks in the same settings file are left exactly where they are.
#
# Usage:
#   guard-toggle.sh on       # restore Belay hooks in settings.json
#   guard-toggle.sh off      # remove Belay hooks from settings.json (scripts stay)
#   guard-toggle.sh status   # show current state

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_FILE="$SCRIPT_DIR/.install-meta.json"
HOOKS_BACKUP="$SCRIPT_DIR/.hooks-backup.json"

# --- Resolve settings file ---
if [ -f "$META_FILE" ]; then
  SETTINGS_FILE=$(jq -r '.settings_file' "$META_FILE" 2>/dev/null)
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
fi

# --- Check dependencies ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it with: brew install jq (macOS) or apt install jq (Linux)"
  exit 1
fi

# --- Identifying our own entries ---
# A hook is Belay's if its command lives under the Belay directory, or is one
# of our two entry-point scripts. Anything else belongs to the user.
JQ_IS_BELAY='
def is_belay($d):
  (.command // "")
  | (($d != "" and contains($d))
     or test("(^|/)(belay\\.sh|audit-log\\.sh)([[:space:]]|$)")
     or contains("/.belay/"));
'

# Strip Belay entries from one event array, dropping matcher groups that end
# up with no hooks left.
JQ_CLEAN_EVENT="$JQ_IS_BELAY"'
def clean_event($d):
  map(.hooks = ((.hooks // []) | map(select(is_belay($d) | not))))
  | map(select((.hooks // []) | length > 0));
'

# Everything of ours currently registered, in the same shape as HOOKS_JSON.
JQ_EXTRACT="$JQ_IS_BELAY"'
def only_belay($d):
  map(.hooks = ((.hooks // []) | map(select(is_belay($d)))))
  | map(select((.hooks // []) | length > 0));
{
  PreToolUse:  ((.hooks.PreToolUse  // []) | only_belay($dir)),
  PostToolUse: ((.hooks.PostToolUse // []) | only_belay($dir))
}
| with_entries(select((.value | length) > 0))
'

# Settings with all Belay entries removed, and empty containers pruned.
JQ_STRIP="$JQ_CLEAN_EVENT"'
.hooks = ((.hooks // {})
          | .PreToolUse  = ((.PreToolUse  // []) | clean_event($dir))
          | .PostToolUse = ((.PostToolUse // []) | clean_event($dir))
          | with_entries(select((.value | length) > 0)))
| if (.hooks | length) == 0 then del(.hooks) else . end
'

# --- Helpers ---
belay_hook_count() {
  [ -f "$SETTINGS_FILE" ] || { echo 0; return; }
  jq --arg dir "$SCRIPT_DIR" "$JQ_IS_BELAY"'
    [ (.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | select(is_belay($dir)) ] | length
  ' "$SETTINGS_FILE" 2>/dev/null || echo 0
}

has_hooks() {
  [ "$(belay_hook_count)" -gt 0 ] 2>/dev/null
}

write_settings() {
  # $1 = new JSON. Written via temp file so a jq failure can't truncate settings.
  printf '%s' "$1" | jq '.' > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
}

show_status() {
  echo "Settings file: $SETTINGS_FILE"
  echo ""
  if has_hooks; then
    echo "Status: ON"
    echo ""
    echo "Belay hooks:"
    jq -r --arg dir "$SCRIPT_DIR" "$JQ_IS_BELAY"'
      (.hooks // {}) | to_entries[]
      | .key as $event | .value[]
      | .matcher as $m | (.hooks // [])[]
      | select(is_belay($dir))
      | "  \($event)  matcher: \($m)  command: \(.command)"
    ' "$SETTINGS_FILE" 2>/dev/null || echo "  (none)"

    local others
    others=$(jq --arg dir "$SCRIPT_DIR" "$JQ_IS_BELAY"'
      [ (.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | select(is_belay($dir) | not) ] | length
    ' "$SETTINGS_FILE" 2>/dev/null || echo 0)
    if [ "${others:-0}" -gt 0 ] 2>/dev/null; then
      echo ""
      echo "Other hooks in this file: $others (left alone by belay on/off)"
    fi
  else
    echo "Status: OFF"
    if [ -f "$HOOKS_BACKUP" ]; then
      echo "Backup available. Restore with:  $SCRIPT_DIR/guard-toggle.sh on"
    else
      echo "No backup found. Reinstall with:  $SCRIPT_DIR/../setup.sh"
    fi
  fi
}

turn_off() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "No settings file at $SETTINGS_FILE — nothing to remove."
    exit 0
  fi

  if ! has_hooks; then
    echo "Belay hooks are already off."
    exit 0
  fi

  # Back up only our entries, so `on` can put back exactly what it removed.
  jq --arg dir "$SCRIPT_DIR" "$JQ_EXTRACT" "$SETTINGS_FILE" > "$HOOKS_BACKUP"
  echo "Belay hooks backed up to $HOOKS_BACKUP"

  write_settings "$(jq --arg dir "$SCRIPT_DIR" "$JQ_STRIP" "$SETTINGS_FILE")"

  echo "Belay hooks removed from $SETTINGS_FILE"
  echo "Your other hooks were left untouched."
  echo "Guard scripts are still installed at $SCRIPT_DIR"
  echo ""
  echo "Restore with:  $SCRIPT_DIR/guard-toggle.sh on"
}

turn_on() {
  if has_hooks; then
    echo "Belay hooks are already on."
    show_status
    exit 0
  fi

  if [ ! -f "$HOOKS_BACKUP" ]; then
    echo "ERROR: No hooks backup found at $HOOKS_BACKUP"
    echo "Reinstall with:  $SCRIPT_DIR/../setup.sh"
    exit 1
  fi

  if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
  fi

  # Strip first, then append: makes re-running this idempotent even if a
  # partial set of our hooks is still registered.
  write_settings "$(jq --arg dir "$SCRIPT_DIR" --slurpfile b "$HOOKS_BACKUP" \
    "$JQ_STRIP"'
      | .hooks = ((.hooks // {})
                  | .PreToolUse  = ((.PreToolUse  // []) + ($b[0].PreToolUse  // []))
                  | .PostToolUse = ((.PostToolUse // []) + ($b[0].PostToolUse // []))
                  | with_entries(select((.value | length) > 0)))
    ' "$SETTINGS_FILE")"

  echo "Belay hooks restored in $SETTINGS_FILE"
  echo ""
  show_status
}

# --- Main ---
ACTION="${1:-status}"

case "$ACTION" in
  on)
    turn_on
    ;;
  off)
    turn_off
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: guard-toggle.sh [on|off|status]"
    echo ""
    echo "  on      Restore Belay hooks in settings.json"
    echo "  off     Remove Belay hooks from settings.json (keeps scripts)"
    echo "  status  Show current state"
    exit 1
    ;;
esac
