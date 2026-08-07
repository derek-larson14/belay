#!/bin/bash
# Install Grok Build hooks for belay core
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
mkdir -p "$HOOK_DIR"

# Resolve pretool to absolute path
PRETOOL="$ROOT/adapters/grok/pretool.sh"
chmod +x "$PRETOOL" "$ROOT/core/"*.sh "$ROOT/belay.sh" "$ROOT/guards/"*.sh 2>/dev/null || true

# Write hooks file with absolute command path
jq -n \
  --arg cmd "$PRETOOL" \
  '{
    hooks: {
      PreToolUse: [
        {
          matcher: "Bash|Read|Edit|Write|Grep|Glob|run_terminal_command|read_file|search_replace|list_dir|grep",
          hooks: [
            { type: "command", command: $cmd, timeout: 15 }
          ]
        }
      ]
    }
  }' > "$HOOK_DIR/belay.json"

echo "Installed: $HOOK_DIR/belay.json"
echo "Command:   $PRETOOL"
echo "Restart Grok (or open a new session) so hooks reload."
echo "Trust project hooks if prompted: /hooks-trust"
