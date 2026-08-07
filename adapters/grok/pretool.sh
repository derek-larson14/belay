#!/bin/bash
# Grok Build PreToolUse entrypoint
# Installed via ~/.grok/hooks/belay.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${BELAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export BELAY_ROOT="$ROOT"
export BELAY_HARNESS=grok

exec bash "$ROOT/core/dispatch.sh"
