#!/bin/bash
# bridge.sh — Pi tool_call JSON → core/dispatch (RESPONSE=pi)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${BELAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export BELAY_ROOT="$ROOT"
export BELAY_HARNESS=pi

exec bash "$ROOT/core/dispatch.sh"
