#!/usr/bin/env bash
# PostToolUse gate: after an Edit or Write, run the project's tests for the area that changed.
#
# The gates belong to the project, not to this plugin: they are read from
# $CLAUDE_PROJECT_DIR/.claude/gates.json (or the path given with --config). No file, no gates —
# the hook exits 0 and stays silent, so installing the plugin never runs an unknown build command.
#
# Exit codes: 0 = nothing to do, or the tests passed. 2 = the tests failed, and stderr is handed
# back to Claude as feedback.
#
# Only Edit and Write reach this hook. Edits made through Bash (heredoc, sed, python) do not;
# test-gate-stop.sh is the backstop for those.
set -uo pipefail

config=".claude/gates.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) shift; [ $# -gt 0 ] && [ -n "$1" ] && config="$1" ;;
  esac
  shift
done
# A literal ${...} here means this Claude Code build does not substitute user config in hook
# args; fall back to the documented default rather than looking for a file with that name.
case "$config" in *'${'*) config=".claude/gates.json" ;; esac

# The option is exported to hook commands; the exact case of the suffix has varied, so accept both.
enabled="${CLAUDE_PLUGIN_OPTION_GATES_ENABLED:-${CLAUDE_PLUGIN_OPTION_gates_enabled:-true}}"
[ "$enabled" = "false" ] && exit 0

input=$(cat)
project="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$project" || exit 0
[ -f "$config" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

file=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' <<<"$input" 2>/dev/null)
[ -n "$file" ] || exit 0
rel=${file#"$project"/}

count=$(jq 'if type == "object" and (.gates | type) == "array" then (.gates | length) else -1 end' \
  "$config" 2>/dev/null) || count=-1
if [ "${count:--1}" -lt 0 ]; then
  jq -n --arg c "$config" \
    '{systemMessage: ("Test gates are off: \($c) is not an object with a \"gates\" array.")}'
  exit 0
fi

i=0
while [ "$i" -lt "$count" ]; do
  gate=$(jq -c ".gates[$i]" "$config"); i=$((i + 1))

  # A gate with no "on" runs on both events.
  jq -e '(.on // ["edit","stop"]) | index("edit")' >/dev/null 2>&1 <<<"$gate" || continue
  cmd=$(jq -r '.command // empty' <<<"$gate"); [ -n "$cmd" ] || continue

  # Patterns are shell globs against the project-relative path. Note that * crosses "/" here,
  # so "src/*/foo/*.kt" matches at any depth; brace alternatives are not expanded — list them
  # as separate entries in "paths".
  matched=false
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2053  # the right-hand side is a glob on purpose
    if [[ $rel == $pattern ]]; then matched=true; break; fi
  done < <(jq -r '.paths[]? // empty' <<<"$gate")
  $matched || continue

  name=$(jq -r '.name // "tests"' <<<"$gate")
  errors=$(jq -r '.errorPattern // empty' <<<"$gate")
  [ -n "$errors" ] || errors='FAILED|AssertionError|assert|expected:|^e: |error:|No tests found|What went wrong'

  log=$(mktemp -t claude-gate)
  if bash -c "$cmd" >"$log" 2>&1; then
    rm -f "$log"
    continue
  fi

  {
    echo "Gate \"$name\" FAILED after editing $rel."
    echo "Command: $cmd"
    echo "Fix this before moving on."
    # The failing assertions and compiler errors; the full log stays on disk.
    grep -E "$errors" -A2 "$log" | head -40
    echo "Full log: $log"
  } >&2
  exit 2
done
exit 0
