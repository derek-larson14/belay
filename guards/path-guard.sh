#!/bin/bash
# path-guard.sh — PreToolUse hook that blocks access to sensitive local data
#
# Claude Code calls this before Read, Grep, Glob, Edit, and Bash tools.
# It receives JSON on stdin with tool_name and tool_input.
#
# Categories can be toggled in belay.toml under [path-guard.categories].
# Missing categories default to ON — you must explicitly disable them.
#
# Philosophy: these are paths no AI agent should ever need to access.
# .env files are the exception: processes may load them, but dumping
# contents into the model is blocked unless env_files allows it.

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Extract the path/command to check based on tool type
case "$TOOL_NAME" in
  Read|Edit|Write)
    CHECK_STRING=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Grep)
    CHECK_STRING=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)
    ;;
  Glob)
    GLOB_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null)
    GLOB_PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty' 2>/dev/null)
    CHECK_STRING="$GLOB_PATH/$GLOB_PATTERN"
    ;;
  Bash)
    CHECK_STRING=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac

# If nothing to check, allow
[ -z "$CHECK_STRING" ] && exit 0

# Normalize home-relative spellings before matching. The blocklist is written
# in absolute form ($HOME/.ssh), but agents write `~/.ssh/id_rsa` or
# `$HOME/.ssh/id_rsa`, and a literal substring match never sees those as the
# same path — so the most obvious way to ask for a secret sailed straight
# through. Expand them to the real path first.
CHECK_STRING="${CHECK_STRING//\$\{HOME\}/$HOME}"
CHECK_STRING="${CHECK_STRING//\$HOME/$HOME}"
CHECK_STRING="${CHECK_STRING//\~\//$HOME/}"

# Original bash command, before we append cwd and resolved targets.
# Dump-vs-load uses this so `source .env && npm test` is a load, not a dump.
BASH_CMD=""
[ "$TOOL_NAME" = "Bash" ] && BASH_CMD="$CHECK_STRING"

# Resolve relative paths against the session's working directory — the approach
# pi-guardrails uses. Without it, an agent already sitting inside a sensitive
# directory just reads `id_rsa` and there is no absolute path to match on.
SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$SESSION_CWD" ] && SESSION_CWD="$PWD"

case "$TOOL_NAME" in
  Read|Edit|Write|Grep|Glob)
    if [ "${CHECK_STRING#/}" = "$CHECK_STRING" ]; then
      CHECK_STRING="$SESSION_CWD/${CHECK_STRING#./}"
    fi
    ;;
  Bash)
    # A shell command issued from inside a sensitive directory is itself
    # suspect, so the working directory is part of what gets checked.
    CHECK_STRING="$CHECK_STRING
$SESSION_CWD"

    # Substring matching cannot see `cat canary.txt` for what it is. Pull out
    # path-like arguments, expand ~ and globs, resolve each against cwd, and
    # append the absolute forms so the normal pattern check catches them.
    # This is a best-effort tokenizer, not a shell parser — see README.
    _bash_targets() {
      local cmd="$1" cwd="$2" tok expanded
      cmd="${cmd//|/ }"; cmd="${cmd//;/ }"; cmd="${cmd//&/ }"
      cmd="${cmd//\`/ }"; cmd="${cmd//$'\n'/ }"
      cmd="${cmd//>/ }"; cmd="${cmd//</ }"
      for tok in $cmd; do
        tok="${tok%\"}"; tok="${tok#\"}"
        tok="${tok%\'}"; tok="${tok#\'}"
        [ -z "$tok" ] && continue
        case "$tok" in -*) continue ;; esac
        # Only things that look like paths
        case "$tok" in */*|.*|*.*) ;; *) continue ;; esac
        tok="${tok/#\~\//$HOME/}"
        case "$tok" in /*) ;; *) tok="$cwd/${tok#./}" ;; esac
        # Expand globs when they resolve; otherwise keep the literal token
        if case "$tok" in *[\*\?\[]*) true ;; *) false ;; esac; then
          expanded=$(compgen -G "$tok" 2>/dev/null)
          [ -n "$expanded" ] && printf '%s\n' "$expanded" && continue
        fi
        printf '%s\n' "$tok"
      done
    }
    BASH_TARGETS=$(_bash_targets "$CHECK_STRING" "$SESSION_CWD")
    [ -n "$BASH_TARGETS" ] && CHECK_STRING="$CHECK_STRING
$BASH_TARGETS"
    ;;
esac

# For Bash: git commands don't access file contents — commit messages, tag
# messages, and log output can mention sensitive paths without it being a
# real file access. Skip named path categories for git to avoid those false
# positives. Dotenv dump checks still run (`git show .env` is a dump).
GIT_SKIP_PATHS=false
if [ "$TOOL_NAME" = "Bash" ]; then
  _git_re='^[[:space:]]*git([^[:alnum:]_]|$)'
  if [[ "$CHECK_STRING" =~ $_git_re ]]; then
    GIT_SKIP_PATHS=true
  fi
fi

HOME_DIR="$HOME"

# === CONFIG HELPERS ===
. "$(cd "$(dirname "$0")/.." && pwd)/core/config.sh"

# Check if a category is enabled. Defaults to ON if not specified.
# Env override: BELAY_PATH_CAT_<CATEGORY>=off
# Known categories are mapped without `tr` — 11 tr processes were ~80ms
# on the PreToolUse hot path.
category_enabled() {
  local cat_name="$1" env_var
  case "$cat_name" in
    credentials)        env_var=BELAY_PATH_CAT_CREDENTIALS ;;
    browser-sessions)   env_var=BELAY_PATH_CAT_BROWSER_SESSIONS ;;
    messages)           env_var=BELAY_PATH_CAT_MESSAGES ;;
    keychains)          env_var=BELAY_PATH_CAT_KEYCHAINS ;;
    password-managers)  env_var=BELAY_PATH_CAT_PASSWORD_MANAGERS ;;
    system-data)        env_var=BELAY_PATH_CAT_SYSTEM_DATA ;;
    shell-history)      env_var=BELAY_PATH_CAT_SHELL_HISTORY ;;
    claude-internals)   env_var=BELAY_PATH_CAT_CLAUDE_INTERNALS ;;
    clipboard)          env_var=BELAY_PATH_CAT_CLIPBOARD ;;
    browser-hijacking)  env_var=BELAY_PATH_CAT_BROWSER_HIJACKING ;;
    *) env_var="BELAY_PATH_CAT_$(echo "$cat_name" | tr '[:lower:]-' '[:upper:]_')" ;;
  esac
  local env_val="${!env_var:-}"
  [ "$env_val" = "off" ] && return 1
  [ "$env_val" = "on" ] && return 0

  belay_config "path-guard.categories" "$cat_name" "true" >/dev/null
  [ "$BELAY_CONFIG_VAL" = "true" ]
}

# === DENY HELPER ===
deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# True if $2 appears in $1 as a whole path component.
# Same boundary rule as the old grep -E:
#   preceded by start / whitespace / ' / " / = / /
#   followed by end / / / whitespace / ' / "
# In-process so `cd ~ && cat .ssh/id_rsa` still hits, `core.sshCommand` does not.
_has_path_component() {
  local s="$1" rel="$2" prefix rest prev next
  case "$s" in
    *"$rel"*) ;;
    *) return 1 ;;
  esac
  prefix="${s%%"$rel"*}"
  rest="${s#*"$rel"}"
  if [ -n "$prefix" ]; then
    prev="${prefix#"${prefix%?}"}"
    case "$prev" in
      [[:space:]]|"'"|'"'|'='|'/') ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "$rest" ]; then
    next="${rest%"${rest#?}"}"
    case "$next" in
      '/'|[[:space:]]|"'"|'"') ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Escape an ERE so it can be interpolated into [[ =~ ]] without a sed process.
# Only used off the allow-path hot path (self-protect).
_ere_escape() {
  local s="$1" i c out=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\'|'.'|'['|']'|'^'|'$'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Secret dotenv filenames: `.env` and `.env.<x>`. Templates (`.env.example`)
# and unrelated names (`.env-project-allowed`, `.environment`, `.venv`) are not.
_is_secret_dotenv_basename() {
  local base="$1"
  case "$base" in
    .env) return 0 ;;
    .env.example|.env.sample|.env.template) return 1 ;;
    .env.example.*|.env.sample.*|.env.template.*) return 1 ;;
    .env.*) return 0 ;;
    *) return 1 ;;
  esac
}

_path_is_secret_dotenv() {
  local p="$1"
  p="${p%/}"
  [ -n "$p" ] || return 1
  _is_secret_dotenv_basename "${p##*/}"
}

_is_home_root_dotenv() {
  local p="$1"
  p="${p%/}"
  case "$p" in
    "$HOME_DIR"/.env|"$HOME_DIR"/.env.*)
      _is_secret_dotenv_basename "${p##*/}"
      ;;
    *) return 1 ;;
  esac
}

_resolve_maybe_rel() {
  local tok="$1"
  tok="${tok/#\~\//$HOME_DIR/}"
  case "$tok" in
    /*) printf '%s' "$tok" ;;
    *) printf '%s' "${SESSION_CWD:-$PWD}/${tok#./}" ;;
  esac
}

# True if this dotenv path should be blocked under the current mode.
_dotenv_path_blocked() {
  local p="$1"
  _path_is_secret_dotenv "$p" || return 1
  case "$DOTENV_MODE" in
    allow) return 1 ;;
    project) _is_home_root_dotenv "$p" ;;
    *) return 0 ;;
  esac
}

_is_dump_command() {
  local cmd="$1" re
  re='(^|[[:space:];|&])(cat|head|tail|less|more|bat|batcat|nl|od|xxd|hexdump|strings|grep|egrep|fgrep|rg|ag|ack|sed|awk|cut|tee|cp|mv)([[:space:]]|$)'
  [[ "$cmd" =~ $re ]] && return 0
  re='(^|[[:space:];|&])git[[:space:]]+(show|diff|grep|blame|cat-file)([[:space:]]|$)'
  [[ "$cmd" =~ $re ]]
}

# `echo KEY=x > .env` is a write/dump even though echo itself is not a dumper.
_segment_redirects_blocked_dotenv() {
  local seg="$1" rest tok resolved
  local re='(>>|&>|>)[[:space:]]*['\''"]?([^'\''"[:space:]]+)'
  local n=0
  rest="$seg"
  while [[ "$rest" =~ $re ]]; do
    n=$((n+1))
    [ "$n" -gt 8 ] && break
    tok="${BASH_REMATCH[2]}"
    if _path_is_secret_dotenv "$tok"; then
      resolved=$(_resolve_maybe_rel "$tok")
      _dotenv_path_blocked "$resolved" && return 0
    fi
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  return 1
}

# True if a bash command dumps a blocked dotenv file into the model.
# Per-pipeline-segment: `sed -i s/a/b/ src.js && npm --env-file .env` is a load.
_bash_dumps_blocked_dotenv() {
  local cmd="$1" segs seg tok tmp resolved re
  cmd="${cmd%%<<*}"
  segs="$cmd"
  segs="${segs//&&/$'\n'}"
  segs="${segs//||/$'\n'}"
  segs="${segs//|/$'\n'}"
  segs="${segs//;/$'\n'}"
  segs="${segs//&/$'\n'}"
  re="(open|read_text|readFileSync|readFile|Path)\\(['\"]([^'\"]+)['\"]"
  while IFS= read -r seg || [ -n "$seg" ]; do
    [ -z "$seg" ] && continue
    _segment_redirects_blocked_dotenv "$seg" && return 0
    if [[ "$seg" =~ $re ]]; then
      tok="${BASH_REMATCH[2]}"
      if _path_is_secret_dotenv "$tok"; then
        resolved=$(_resolve_maybe_rel "$tok")
        _dotenv_path_blocked "$resolved" && return 0
      fi
    fi
    _is_dump_command "$seg" || continue
    tmp="$seg"
    tmp="${tmp//>/ }"
    tmp="${tmp//</ }"
    tmp="${tmp//\`/ }"
    for tok in $tmp; do
      tok="${tok%\"}"; tok="${tok#\"}"
      tok="${tok%\'}"; tok="${tok#\'}"
      [ -z "$tok" ] && continue
      case "$tok" in -*) continue ;; esac
      _path_is_secret_dotenv "$tok" || continue
      resolved=$(_resolve_maybe_rel "$tok")
      if _dotenv_path_blocked "$resolved"; then
        return 0
      fi
    done
  done <<< "$segs"
  return 1
}

_dotenv_deny_reason() {
  if [ "$DOTENV_MODE" = "project" ]; then
    echo "BLOCKED: home directory .env files may contain production secrets. Project .env files are allowed."
  else
    echo "BLOCKED: reading .env files dumps credentials into the model. Let the process load them, or set path-guard.env_files = \"project\" to allow reading project .env files."
  fi
}

check_patterns() {
  [ "${GIT_SKIP_PATHS:-false}" = true ] && return 0
  local category="$1"
  shift
  local pattern rel
  for pattern in "$@"; do
    # bash substring match — same as grep -F, no process
    if [[ "$CHECK_STRING" == *"$pattern"* ]]; then
      deny "BLOCKED: access to sensitive path matching '$pattern'. This contains credentials, messages, browser sessions, or system secrets. Ask the user to provide this data manually if needed."
    fi

    # A home-rooted pattern can also show up as a bare relative path once the
    # command has cd'd somewhere: `cd ~ && cat .ssh/id_rsa`. Match the part
    # below $HOME as a whole path component so `.ssh` hits but `core.sshCommand`
    # does not.
    case "$pattern" in
      "$HOME_DIR"/*)
        rel="${pattern#"$HOME_DIR"/}"
        if _has_path_component "$CHECK_STRING" "$rel"; then
          deny "BLOCKED: access to sensitive path matching '$pattern'. This contains credentials, messages, browser sessions, or system secrets. Ask the user to provide this data manually if needed."
        fi
        ;;
    esac
  done
}

# === CATEGORIES ===
# Each category is a named group of patterns. Categories default to ON.
# Disable in belay.toml under [path-guard.categories] or via env var.

if category_enabled "credentials"; then
  check_patterns "credentials" \
    "$HOME_DIR/.ssh" \
    "$HOME_DIR/.aws" \
    "$HOME_DIR/.anthropic" \
    "$HOME_DIR/.config/gh/hosts" \
    "$HOME_DIR/.config/gcloud" \
    "$HOME_DIR/.config/rclone/rclone.conf" \
    "$HOME_DIR/.config/stripe" \
    "$HOME_DIR/.npmrc" \
    "$HOME_DIR/.docker/config.json" \
    "$HOME_DIR/.claude.json" \
    "$HOME_DIR/.kube/config" \
    "$HOME_DIR/.terraform.d/credentials" \
    "$HOME_DIR/.netrc" \
    "$HOME_DIR/.pgpass"
fi

if category_enabled "browser-sessions"; then
  check_patterns "browser-sessions" \
    "$HOME_DIR/Library/Cookies" \
    "$HOME_DIR/Library/Safari" \
    "Library/Application Support/Google/Chrome" \
    "Library/Application Support/Arc" \
    "Library/Application Support/Firefox" \
    "Library/Application Support/BraveSoftware" \
    "Library/Application Support/Microsoft Edge" \
    "Library/Application Support/Dia" \
    "$HOME_DIR/.config/google-chrome" \
    "$HOME_DIR/.config/chromium" \
    "$HOME_DIR/.mozilla/firefox" \
    "$HOME_DIR/.config/BraveSoftware"
fi

if category_enabled "messages"; then
  check_patterns "messages" \
    "$HOME_DIR/Library/Messages" \
    "$HOME_DIR/Library/Mail" \
    "Library/Application Support/Signal"
fi

if category_enabled "keychains"; then
  check_patterns "keychains" \
    "$HOME_DIR/Library/Keychains" \
    "$HOME_DIR/Library/Accounts" \
    "security dump-keychain" \
    "security find-generic-password" \
    "security find-internet-password" \
    "security export"
fi

if category_enabled "password-managers"; then
  check_patterns "password-managers" \
    "Library/Containers/com.1password" \
    "Library/Group Containers/2BUA8C4S2C.com.1password" \
    "Library/Group Containers/2BUA8C4S2C.com.agilebits" \
    "$HOME_DIR/.config/1Password" \
    "$HOME_DIR/.local/share/keyrings" \
    "$HOME_DIR/.gnupg"
fi

if category_enabled "system-data"; then
  check_patterns "system-data" \
    "Library/Group Containers/group.com.apple.mail" \
    "Library/Group Containers/group.com.apple.messages" \
    "Library/Group Containers/group.com.apple.contacts" \
    "Library/Group Containers/UBF8T346G9.com.microsoft.oneauth" \
    "Library/Group Containers/UBF8T346G9.com.microsoft.entrabroker"
fi

if category_enabled "shell-history"; then
  check_patterns "shell-history" \
    "$HOME_DIR/.bash_history" \
    "$HOME_DIR/.zsh_history" \
    "$HOME_DIR/.zsh_sessions" \
    "$HOME_DIR/.psql_history" \
    "$HOME_DIR/.python_history" \
    "$HOME_DIR/.node_repl_history" \
    "$HOME_DIR/.lesshst" \
    "$HOME_DIR/.mysql_history" \
    "$HOME_DIR/.rediscli_history"
fi

if category_enabled "claude-internals"; then
  check_patterns "claude-internals" \
    "$HOME_DIR/.claude/history.jsonl" \
    "$HOME_DIR/.claude/paste-cache" \
    "$HOME_DIR/.claude/backups" \
    "$HOME_DIR/.claude/session-env" \
    "$HOME_DIR/.claude/shell-snapshots" \
    "$HOME_DIR/.claude/file-history" \
    "$HOME_DIR/.claude/debug" \
    "$HOME_DIR/.claude/cache" \
    "$HOME_DIR/.claude/downloads"
fi

if category_enabled "clipboard"; then
  check_patterns "clipboard" \
    "pbpaste" \
    "pbcopy" \
    "the clipboard" \
    "NSPasteboard" \
    "generalPasteboard" \
    "UIPasteboard" \
    "xclip" \
    "xsel" \
    "wl-paste" \
    "wl-copy" \
    "com.generalarcade.flycut"
fi

if category_enabled "browser-hijacking"; then
  check_patterns "browser-hijacking" \
    "remote-debugging-port" \
    "remote-debugging-pipe" \
    "remote-debugging-address" \
    "RemoteDebugging" \
    "DevTools" \
    "chrome-remote-interface" \
    "puppeteer.connect" \
    "playwright.connect"
fi

# === SELF-PROTECTION (off by default) ===
# Blocks modifications to guard scripts and Claude settings.
# Off by default because hooks are snapshotted at session start.
# Even if Claude edits settings.json mid-session, the hooks don't change
# until the next session. For autonomous sessions (claude -p), the session
# is single-shot, so edits can't affect the current run.
#
# Turn this on if you want to prevent Claude from editing settings across
# sessions (e.g. agent removes hooks in session 1, session 2 starts unprotected).
# To enable: set BELAY_SELF_PROTECT=on or uncomment below.
SELF_PROTECT="${BELAY_SELF_PROTECT:-off}"

if [ "$SELF_PROTECT" = "on" ]; then

# Protected locations are resolved at runtime from where this guard actually
# lives. Matching a hardcoded name like "belay" meant renaming the install
# directory silently turned self-protection off, and any unrelated path
# containing that word got blocked. Neither is acceptable for a security check.
GUARD_SRC="$(cd "$(dirname "$0")/.." && pwd)"

SELF_PROTECT_PATHS=(
  "$GUARD_SRC"
  "$(belay_home)"
  "$HOME/.claude/settings.json"
  "${PI_HOME:-$HOME/.pi}/agent/extensions/belay"
  "${GROK_HOME:-$HOME/.grok}/hooks/belay.json"
)
[ -n "${BELAY_ROOT:-}" ] && SELF_PROTECT_PATHS+=("$BELAY_ROOT")

# Absolute-path matching misses `cd ~/.belay && rm belay.sh`, so the guard
# filenames themselves are protected too. Only distinctive names — nothing
# generic enough to collide with an unrelated file.
SELF_PROTECT_NAMES=(
  "belay.sh" "guard-toggle.sh" "audit-log.sh"
  "path-guard.sh" "write-guard.sh" "network-guard.sh" "workspace-guard.sh"
)

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Bash" ]; then
  # Resolve relative file paths so `Edit belay.sh` from inside the install
  # directory is checked against the same absolute paths as everything else.
  SELF_CHECK="$CHECK_STRING"
  if [ "$TOOL_NAME" != "Bash" ] && [ "${SELF_CHECK#/}" = "$SELF_CHECK" ]; then
    SELF_CHECK="$PWD/$SELF_CHECK"
  fi

  # Read-only Bash commands may reference these paths freely
  SELF_READONLY=false
  _ro_re='^(cat |head |tail |less |more |wc |file |stat |ls |diff |md5 |shasum |grep |egrep |fgrep |rg )'
  if [ "$TOOL_NAME" = "Bash" ] && [[ "$CHECK_STRING" =~ $_ro_re ]]; then
    SELF_READONLY=true
  fi

  if [ "$SELF_READONLY" = false ]; then
    for sp in "${SELF_PROTECT_PATHS[@]}"; do
      [ -n "$sp" ] || continue
      if [ "$TOOL_NAME" != "Bash" ]; then
        # Exact path or a child of it. Substring matching would treat
        # ~/Github/belay-experiments as part of ~/Github/belay.
        case "$SELF_CHECK" in
          "$sp"|"$sp"/*) deny "BLOCKED: cannot modify Belay's own scripts, config, or harness hook wiring. To turn guards off, run this yourself in a terminal: $(belay_home)/guard-toggle.sh off" ;;
        esac
      else
        # Same boundary rule inside a command line: the path must end or be
        # followed by a separator, never by more path characters.
        sp_re=$(_ere_escape "$sp")
        sp_re="(^|[[:space:]'\"=])${sp_re}(/|[[:space:]'\";|&]|$)"
        if [[ "$SELF_CHECK" =~ $sp_re ]]; then
          deny "BLOCKED: cannot modify Belay's own scripts, config, or harness hook wiring. To turn guards off, run this yourself in a terminal: $(belay_home)/guard-toggle.sh off"
        fi
      fi
    done
    for sn in "${SELF_PROTECT_NAMES[@]}"; do
      sn_re="(^|[/[:space:]'\"])$(_ere_escape "$sn")([[:space:]]|$|['\"])"
      if [[ "$SELF_CHECK" =~ $sn_re ]]; then
        deny "BLOCKED: cannot modify Belay's own scripts, config, or harness hook wiring. To turn guards off, run this yourself in a terminal: $(belay_home)/guard-toggle.sh off"
      fi
    done
  fi
fi
fi  # end self-protect check

# === CUSTOM BLOCKLIST ===
# Load additional patterns from a user-local file.
# Default: ~/.belay/custom-patterns.txt
# Override: BELAY_CUSTOM_BLOCKLIST=/path/to/file
# Format: one pattern per line, # comments, $HOME expanded automatically.
CUSTOM_LIST="${BELAY_CUSTOM_BLOCKLIST:-$(belay_home)/custom-patterns.txt}"
if [ -f "$CUSTOM_LIST" ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line/\$HOME/$HOME_DIR}"
    if [[ "$CHECK_STRING" == *"$line"* ]]; then
      deny "BLOCKED: access to sensitive path matching '$line'. This contains credentials, messages, browser sessions, or system secrets. Ask the user to provide this data manually if needed."
    fi
  done < "$CUSTOM_LIST"
fi

# === .env files ===
# Independent of the credentials category.
#   block   (default) — deny dumping contents into the model; processes may load them
#   project           — same, except project .env files may be read
#   allow             — no dotenv restrictions
# Glob is filenames only, so it is not a dump.

belay_env_files_mode >/dev/null
DOTENV_MODE="$BELAY_CONFIG_VAL"

if [ "$DOTENV_MODE" != "allow" ] && [ "$TOOL_NAME" != "Glob" ]; then
  case "$TOOL_NAME" in
    Read|Edit|Write|Grep)
      if _dotenv_path_blocked "$CHECK_STRING"; then
        deny "$(_dotenv_deny_reason)"
      fi
      ;;
    Bash)
      if _bash_dumps_blocked_dotenv "$BASH_CMD"; then
        deny "$(_dotenv_deny_reason)"
      fi
      ;;
  esac
fi

# Allow everything else
exit 0
