#!/bin/bash
# Claude Code PreToolUse entrypoint (canonical path)
# hooks/hooks.json can point here; legacy still uses belay.sh at root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${BELAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export BELAY_ROOT="$ROOT"
export BELAY_HARNESS=claude

exec bash "$ROOT/core/dispatch.sh"
