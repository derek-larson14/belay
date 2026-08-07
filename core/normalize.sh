#!/bin/bash
# normalize.sh — any harness PreToolUse/tool_call JSON → canonical schema
# stdin: raw hook/tool payload | stdout: canonical JSON
# See core/schema.md

set -euo pipefail

INPUT=$(cat)

# Already canonical?
if echo "$INPUT" | jq -e '.tool and .args' >/dev/null 2>&1; then
  echo "$INPUT" | jq -c '{tool: .tool, args: (.args // {})}'
  exit 0
fi

# Pull tool name from common shapes
TOOL_RAW=$(echo "$INPUT" | jq -r '
  .toolName // .tool_name // .tool // empty
' 2>/dev/null)

# Pull args object
ARGS_RAW=$(echo "$INPUT" | jq -c '
  .toolInput // .tool_input // .input // .args // {}
' 2>/dev/null)

# Map tool name → canonical
case "$(echo "$TOOL_RAW" | tr '[:upper:]' '[:lower:]')" in
  bash|run_terminal_command|shell|terminal)
    TOOL="bash"
    ;;
  read|read_file)
    TOOL="read"
    ;;
  write|write_file|create_file)
    TOOL="write"
    ;;
  edit|search_replace|multiedit|str_replace|apply_patch)
    TOOL="edit"
    ;;
  grep)
    TOOL="grep"
    ;;
  glob|listdir|list_dir|find|ls)
    TOOL="glob"
    ;;
  *)
    # Unknown — allow path (no policy)
    jq -n --arg t "${TOOL_RAW:-other}" '{tool: "other", args: {}, source_tool: $t}'
    exit 0
    ;;
esac

# Normalize args fields into path/command/pattern
ARGS=$(echo "$ARGS_RAW" | jq -c --arg tool "$TOOL" '
  def path_of:
    .path // .file_path // .target_file // .directory // .file // empty;
  def cmd_of:
    .command // .cmd // empty;
  def pat_of:
    .pattern // .glob // .regex // empty;

  if $tool == "bash" then
    {command: (cmd_of // "")}
  elif $tool == "read" or $tool == "write" or $tool == "edit" then
    {
      path: (path_of // ""),
      content: .content,
      old_string: (.old_string // .oldText // .old_str),
      new_string: (.new_string // .newText // .new_str)
    } | with_entries(select(.value != null and .value != ""))
  elif $tool == "grep" then
    {
      path: ((path_of // ".") | tostring),
      pattern: ((pat_of // "") | tostring)
    }
  elif $tool == "glob" then
    {
      path: ((path_of // ".") | tostring),
      pattern: ((pat_of // "*") | tostring)
    }
  else
    {}
  end
')

jq -n --arg tool "$TOOL" --argjson args "$ARGS" '{tool: $tool, args: $args}'
