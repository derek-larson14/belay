# Canonical tool schema

Internal wire format shared by every harness adapter. Guards never see raw Claude / Pi / Grok payloads — only this.

Adapters: normalize inbound → canonical → `dispatch.sh` → guards → response shaped for the harness.

## Canonical JSON (stdin to dispatch after normalize)

```json
{
  "tool": "bash" | "read" | "write" | "edit" | "grep" | "glob",
  "args": {
    "command": "string, for bash",
    "path": "string, for read/write/edit/grep/glob",
    "pattern": "string, for grep/glob",
    "content": "optional, write",
    "old_string": "optional, edit",
    "new_string": "optional, edit"
  }
}
```

Unknown tools normalize to `{"tool":"other","args":{}}` and are **allowed** (no invented policy).

## Inbound aliases (normalize)

| Canonical tool | Claude Code | Pi | Grok Build |
|----------------|-------------|-----|------------|
| `bash` | `Bash` | `bash` | `run_terminal_command` |
| `read` | `Read` | `read` | `read_file` |
| `write` | `Write` | `write` | *(often `search_replace` create — treat as write if no old)* |
| `edit` | `Edit` | `edit` | `search_replace`, `MultiEdit` |
| `grep` | `Grep` | `grep` | `grep` |
| `glob` | `Glob` | `find`/`ls`/`glob` | `list_dir`, `Glob` |

Path fields accepted: `path`, `file_path`, `target_file`, `directory`.

## Decision (internal)

```json
{ "action": "allow" }
{ "action": "deny", "reason": "..." }
{ "action": "allow", "updated": { "command": "..." } }
```

## Harness response shapes

| Harness | Deny | Allow + mutate |
|---------|------|----------------|
| Claude | `hookSpecificOutput.permissionDecision=deny` | `updatedInput` |
| Pi | `{ "block": true, "reason" }` | `{ "block": false, "updatedInput" }` |
| Grok | `{ "decision": "deny", "reason" }` + exit 2 | Grok has no rewrite API — deny or bare allow only |

## Env

| Var | Meaning |
|-----|---------|
| `BELAY_ROOT` | Belay install root |
| `BELAY_HARNESS` | Which harness's wire format to speak: `claude` \| `pi` \| `grok` (default `claude`) |
| `BELAY_HOME` | State + global config dir (default `~/.belay`) |
| `BELAY_PROJECT_DIR` | Project root override; otherwise detected |
