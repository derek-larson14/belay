#!/bin/bash
# Unit tests for normalize + dispatch (no model)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export BELAY_ROOT="$ROOT"
N="$SCRIPT_DIR/normalize.sh"
D="$SCRIPT_DIR/dispatch.sh"
chmod +x "$N" "$D" "$ROOT/adapters/pi/bridge.sh" 2>/dev/null || true

PASS=0
FAIL=0

check_jq() {
  local desc="$1" expr="$2" json="$3"
  if echo "$json" | jq -e "$expr" >/dev/null 2>&1; then
    echo "  PASS: $desc"
    ((PASS++)) || true
  else
    echo "  FAIL: $desc"
    echo "    expr: $expr"
    echo "    got: $json"
    ((FAIL++)) || true
  fi
}

echo "=== normalize ==="
OUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/a"}}' | "$N")
check_jq "Claude Read → read" '.tool=="read" and .args.path=="/tmp/a"' "$OUT"

OUT=$(echo '{"toolName":"bash","input":{"command":"ls"}}' | "$N")
check_jq "Pi bash → bash" '.tool=="bash" and .args.command=="ls"' "$OUT"

OUT=$(echo '{"toolName":"run_terminal_command","toolInput":{"command":"curl x"}}' | "$N")
check_jq "Grok shell → bash" '.tool=="bash" and .args.command=="curl x"' "$OUT"

OUT=$(echo '{"toolName":"read_file","toolInput":{"target_file":"/home/x/.ssh/id"}}' | "$N")
check_jq "Grok read_file → read path" '.tool=="read" and .args.path=="/home/x/.ssh/id"' "$OUT"

OUT=$(echo '{"toolName":"search_replace","toolInput":{"path":"/tmp/f","oldText":"a","newText":"b"}}' | "$N")
check_jq "Grok search_replace → edit" '.tool=="edit" and .args.path=="/tmp/f"' "$OUT"

echo "=== dispatch (Claude response) ==="
export BELAY_HARNESS=claude
OUT=$(echo '{"toolName":"read_file","toolInput":{"target_file":"'"$HOME"'/.ssh/id_ed25519"}}' | "$D")
check_jq "Grok-shaped payload denied (claude out)" '.hookSpecificOutput.permissionDecision=="deny"' "$OUT"

OUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"'"$ROOT"'/README.md"}}' | "$D")
if [ -z "$OUT" ]; then
  echo "  PASS: allow normal read (empty)"
  ((PASS++)) || true
else
  # empty or no deny
  if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    echo "  FAIL: should allow README"
    ((FAIL++)) || true
  else
    echo "  PASS: allow normal read"
    ((PASS++)) || true
  fi
fi

echo "=== dispatch (Grok response) ==="
export BELAY_HARNESS=grok
set +e
OUT=$(echo '{"toolName":"read_file","toolInput":{"target_file":"'"$HOME"'/.ssh/id_ed25519"}}' | "$D")
EC=$?
set -e
check_jq "Grok deny JSON" '.decision=="deny"' "$OUT"
if [ "$EC" = "2" ]; then
  echo "  PASS: Grok deny exit 2"
  ((PASS++)) || true
else
  echo "  FAIL: Grok deny exit (got $EC)"
  ((FAIL++)) || true
fi

echo "=== dispatch (Pi response) ==="
export BELAY_HARNESS=pi
OUT=$(echo '{"toolName":"bash","input":{"command":"pbpaste"}}' | "$D")
check_jq "Pi block pbpaste" '.block==true' "$OUT"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
