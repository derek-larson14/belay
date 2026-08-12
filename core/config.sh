#!/bin/bash
# config.sh — shared config resolution for every guard and adapter.
# Source this; don't execute it.
#
# Layers, highest wins, resolved per-key (not per-file):
#   1. BELAY_* env var        — caller's business, checked at each call site
#   2. <project>/.belay.toml  — project override
#   3. ~/.belay/config.toml   — user global
#   4. built-in default       — passed by the caller, fail-safe (guards on)
#
# Per-key layering matters: a one-line .belay.toml overrides one setting
# instead of silently discarding the global config.

# --- Where Belay keeps everything ---
belay_home() { echo "${BELAY_HOME:-$HOME/.belay}"; }

# --- Project root, harness-neutral ---
# Explicit > harness hint > nearest .belay.toml > nearest .git > cwd.
# Claude Code sets CLAUDE_PROJECT_DIR; Pi and Grok Build set nothing, so we walk.
_BELAY_PROJECT_DIR=""
belay_project_dir() {
  if [ -n "$_BELAY_PROJECT_DIR" ]; then echo "$_BELAY_PROJECT_DIR"; return; fi

  if [ -n "${BELAY_PROJECT_DIR:-}" ]; then
    _BELAY_PROJECT_DIR="$BELAY_PROJECT_DIR"
    echo "$_BELAY_PROJECT_DIR"; return
  fi

  local start="${CLAUDE_PROJECT_DIR:-$PWD}" d marker
  for marker in .belay.toml .git; do
    d="$start"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if [ -e "$d/$marker" ]; then
        _BELAY_PROJECT_DIR="$d"
        echo "$d"; return
      fi
      d="$(dirname "$d")"
    done
  done

  _BELAY_PROJECT_DIR="$start"
  echo "$start"
}

# --- Parse one TOML file into a blob: \nsection|key=value\n ---
# Same value rules as the old per-key awk: inline comments, quoted #.
# One awk per file per process — PreToolUse used to spawn awk once per key
# (20+ times) and that was a visible slice of the hook.
_belay_parse_toml() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^\[/ {
      sect = $0
      sub(/^\[/, "", sect)
      sub(/\][ \t]*$/, "", sect)
      next
    }
    sect != "" && $1 != "" && $1 !~ /^#/ && index($0, "=") {
      key = $1
      sub(/^[^=]*=[ \t]*/, "")
      if ($0 ~ /^"/) { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "") }
      printf "\n%s|%s=%s", sect, key, $0
    }
  ' "$file"
}

# Look up section|key in a parsed blob. Sets BELAY_BLOB_VAL.
# Returns 0 if present and non-empty (empty = missing, matching old behavior).
# Do not wrap in $() — a subshell is ~10ms on macOS bash 3.2.
_belay_blob_get() {
  local blob="$1" needle=$'\n'"$2|$3=" rest
  rest="${blob#*"$needle"}"
  if [ "$rest" = "$blob" ]; then
    BELAY_BLOB_VAL=""
    return 1
  fi
  rest="${rest%%$'\n'*}"
  if [ -z "$rest" ]; then
    BELAY_BLOB_VAL=""
    return 1
  fi
  BELAY_BLOB_VAL="$rest"
  return 0
}

# --- Read one key from one TOML file. Empty output = not present. ---
# Kept for callers/tests that hit a single file. Prefers the process cache
# when the file is one of the two standard layers.
_belay_toml_get() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  _belay_load_cfg
  if [ "$file" = "$_BELAY_CFG_PROJ_FILE" ]; then
    _belay_blob_get "$_BELAY_CFG_PROJ" "$section" "$key" || return 0
    printf '%s' "$BELAY_BLOB_VAL"
    return
  fi
  if [ "$file" = "$_BELAY_CFG_GLOB_FILE" ]; then
    _belay_blob_get "$_BELAY_CFG_GLOB" "$section" "$key" || return 0
    printf '%s' "$BELAY_BLOB_VAL"
    return
  fi
  _belay_blob_get "$(_belay_parse_toml "$file")" "$section" "$key" || return 0
  printf '%s' "$BELAY_BLOB_VAL"
}

_BELAY_CFG_LOADED=0
_BELAY_CFG_PROJ=""
_BELAY_CFG_GLOB=""
_BELAY_CFG_PROJ_FILE=""
_BELAY_CFG_GLOB_FILE=""

_belay_load_cfg() {
  [ "$_BELAY_CFG_LOADED" = 1 ] && return 0
  _BELAY_CFG_PROJ_FILE="$(belay_project_dir)/.belay.toml"
  _BELAY_CFG_GLOB_FILE="$(belay_home)/config.toml"
  _BELAY_CFG_PROJ="$(_belay_parse_toml "$_BELAY_CFG_PROJ_FILE")"
  _BELAY_CFG_GLOB="$(_belay_parse_toml "$_BELAY_CFG_GLOB_FILE")"
  _BELAY_CFG_LOADED=1
}

# --- Resolve a key through the layers ---
# belay_config <section> <key> [default]
# Sets BELAY_CONFIG_VAL (use that — do not wrap in $(), a subshell is ~10ms).
# Also prints the value so existing $(belay_config ...) callers still work.
belay_config() {
  local section="$1" key="$2" default="${3:-}"
  _belay_load_cfg

  if _belay_blob_get "$_BELAY_CFG_PROJ" "$section" "$key"; then
    BELAY_CONFIG_VAL="$BELAY_BLOB_VAL"
    echo "$BELAY_CONFIG_VAL"; return
  fi
  if _belay_blob_get "$_BELAY_CFG_GLOB" "$section" "$key"; then
    BELAY_CONFIG_VAL="$BELAY_BLOB_VAL"
    echo "$BELAY_CONFIG_VAL"; return
  fi

  BELAY_CONFIG_VAL="$default"
  echo "$default"
}

# --- Which config files are actually in play (for status output) ---
belay_active_configs() {
  local p="$(belay_project_dir)/.belay.toml" g="$(belay_home)/config.toml"
  [ -f "$p" ] && echo "project: $p"
  [ -f "$g" ] && echo "global:  $g"
  return 0
}
