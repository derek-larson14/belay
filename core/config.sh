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

# --- Read one key from one TOML file. Empty output = not present. ---
# Handles inline comments (`x = true  # why`) and quoted values containing #.
_belay_toml_get() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v sect="[$section]" -v k="$key" '
    $0 == sect { in_s=1; next }
    /^\[/ { in_s=0 }
    in_s && $1 == k {
      sub(/^[^=]*=[ \t]*/, "")
      if ($0 ~ /^"/) { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "") }
      print
      exit
    }
  ' "$file"
}

# --- Resolve a key through the layers ---
# belay_config <section> <key> [default]
belay_config() {
  local section="$1" key="$2" default="${3:-}" val

  val=$(_belay_toml_get "$(belay_project_dir)/.belay.toml" "$section" "$key")
  if [ -n "$val" ]; then echo "$val"; return; fi

  val=$(_belay_toml_get "$(belay_home)/config.toml" "$section" "$key")
  if [ -n "$val" ]; then echo "$val"; return; fi

  echo "$default"
}

# --- Which config files are actually in play (for status output) ---
belay_active_configs() {
  local p="$(belay_project_dir)/.belay.toml" g="$(belay_home)/config.toml"
  [ -f "$p" ] && echo "project: $p"
  [ -f "$g" ] && echo "global:  $g"
  return 0
}
