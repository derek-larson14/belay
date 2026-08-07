#!/bin/bash
# belay.sh — single PreToolUse dispatcher for all security guards
#
# Architecture: one hook entry point prevents updatedInput race conditions
# when multiple guards match the same tool. Guards run sequentially;
# first deny wins. updatedInput from network-guard is returned last.
#
# Config: <project>/.belay.toml > ~/.belay/config.toml > built-in defaults
# Env overrides: BELAY_<NAME>=off disables individual guards

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD_DIR="$SCRIPT_DIR/guards"

. "$SCRIPT_DIR/core/config.sh"

get_config() { belay_config "$@"; }

# is_enabled <guard-name> [default]
# Defaults live here, not in a shipped config file, so a machine with no
# config at all still gets the intended posture: protective guards on,
# disruptive guards (network sandbox, workspace jail) opt-in.
is_enabled() {
  local name="$1" default="${2:-true}"
  # Env override: BELAY_PATH_GUARD=off (or =on to force-enable)
  local env_var="BELAY_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
  local env_val="${!env_var:-}"
  [ "$env_val" = "off" ] && return 1
  [ "$env_val" = "on" ] && return 0

  [ "$(get_config "$name" "enabled" "$default")" = "true" ]
}

# --- Read stdin once ---
INPUT=$(cat)
UPDATED_INPUT=""

# --- Run a guard ---
run_guard() {
  local guard="$1"
  [ -x "$guard" ] || return 0

  local output
  output=$(echo "$INPUT" | "$guard")

  [ -z "$output" ] && return 0

  # Deny -> output and short-circuit
  if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "$output"
    exit 0
  fi

  # updatedInput -> save for final response
  if echo "$output" | jq -e '.hookSpecificOutput.updatedInput' >/dev/null 2>&1; then
    UPDATED_INPUT="$output"
  fi
}

# --- Pass config to guards via env vars ---
# "pattern" over "sandbox" as the fallback mode: sandbox-exec wraps every Bash
# call and kills all network, which is not something to inherit by accident.
export BELAY_NETWORK_MODE="${BELAY_NETWORK_MODE:-$(get_config "network-guard" "mode" "pattern")}"
export BELAY_ALLOW_PERSISTENCE="${BELAY_ALLOW_PERSISTENCE:-$(get_config "write-guard" "allow_persistence" "false")}"
export BELAY_ALLOWED_ROOTS="${BELAY_ALLOWED_ROOTS:-$(get_config "workspace-guard" "allowed_roots" "$(belay_project_dir)")}"

# --- Run guards sequentially ---
is_enabled "path-guard"      true  && run_guard "$GUARD_DIR/path-guard.sh"
is_enabled "write-guard"     true  && run_guard "$GUARD_DIR/write-guard.sh"
is_enabled "workspace-guard" false && run_guard "$GUARD_DIR/workspace-guard.sh"
is_enabled "network-guard"   false && run_guard "$GUARD_DIR/network-guard.sh"

# --- Return updatedInput if any guard set one ---
[ -n "$UPDATED_INPUT" ] && echo "$UPDATED_INPUT"

exit 0
