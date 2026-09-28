#!/usr/bin/env bash
# Stop gate: before Claude ends a turn, run the project's stop gates once — whatever tool made
# the edits (Edit/Write, or Bash heredoc/sed/python, which the PostToolUse gate never sees).
#
# Gates are read from $CLAUDE_PROJECT_DIR/.claude/gates.json (or --config). No file, no gates.
#
# Loop guard: exit 2 keeps Claude working and hands it the failure. On the next stop
# stop_hook_active is true; the gates run again, but a failure then only reaches the user as a
# systemMessage and never blocks. So this hook blocks at most once per turn.
set -uo pipefail

config=".claude/gates.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) shift; [ $# -gt 0 ] && [ -n "$1" ] && config="$1" ;;
  esac
  shift
done
case "$config" in *'${'*) config=".claude/gates.json" ;; esac

enabled="${CLAUDE_PLUGIN_OPTION_GATES_ENABLED:-${CLAUDE_PLUGIN_OPTION_gates_enabled:-true}}"
[ "$enabled" = "false" ] && exit 0

input=$(cat)
project="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$project" || exit 0
[ -f "$config" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

active=$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)

count=$(jq 'if type == "object" and (.gates | type) == "array" then (.gates | length) else -1 end' \
  "$config" 2>/dev/null) || count=-1
if [ "${count:--1}" -lt 0 ]; then
  jq -n --arg c "$config" \
    '{systemMessage: ("Test gates are off: \($c) is not an object with a \"gates\" array.")}'
  exit 0
fi

# Collect the gates that run on stop, with their watched patterns.
commands=(); names=(); errorPatterns=(); patterns=()
i=0
while [ "$i" -lt "$count" ]; do
  gate=$(jq -c ".gates[$i]" "$config"); i=$((i + 1))
  jq -e '(.on // ["edit","stop"]) | index("stop")' >/dev/null 2>&1 <<<"$gate" || continue
  cmd=$(jq -r '.command // empty' <<<"$gate"); [ -n "$cmd" ] || continue
  commands+=("$cmd")
  names+=("$(jq -r '.name // "tests"' <<<"$gate")")
  errorPatterns+=("$(jq -r '.errorPattern // empty' <<<"$gate")")
  while IFS= read -r pattern; do
    [ -n "$pattern" ] && patterns+=("$pattern")
  done < <(jq -r '.paths[]? // empty' <<<"$gate")
done
[ "${#commands[@]}" -gt 0 ] || exit 0

# Most turns are conversation, not code. The state file holds the commit at the last green run;
# its mtime marks when that run finished, so an untouched tree costs nothing.
state="${TMPDIR:-/tmp}/claude-gates-$(printf %s "$project" | shasum | cut -c1-12)"
head=$(git -C "$project" rev-parse HEAD 2>/dev/null || echo no-git)
if [ -f "$state" ] && [ "$head" = "$(cat "$state" 2>/dev/null)" ]; then
  shopt -s nullglob globstar
  touched=false
  for pattern in "${patterns[@]}"; do
    # shellcheck disable=SC2206  # the pattern is expanded as a glob on purpose
    for f in $pattern; do
      if [ -f "$f" ] && [ "$f" -nt "$state" ]; then touched=true; break 2; fi
    done
  done
  shopt -u nullglob globstar
  $touched || exit 0
fi

failures=""
j=0
while [ "$j" -lt "${#commands[@]}" ]; do
  cmd="${commands[$j]}"; name="${names[$j]}"; errors="${errorPatterns[$j]}"; j=$((j + 1))
  [ -n "$errors" ] || errors='FAILED|AssertionError|assert|expected:|^e: |error:|No tests found|What went wrong'

  log=$(mktemp -t claude-gate-stop)
  if bash -c "$cmd" >"$log" 2>&1; then
    rm -f "$log"
    continue
  fi
  failures+="Gate \"$name\" FAILED. Command: $cmd"$'\n'
  failures+="$(grep -E "$errors" -A2 "$log" | head -40)"$'\n'
  failures+="Full log: $log"$'\n'
done

if [ -z "$failures" ]; then
  printf %s "$head" > "$state"
  exit 0
fi

if [ "$active" = "true" ]; then
  # Already blocked once and Claude tried to fix it: tell the user instead of blocking again.
  jq -n --arg m "Test gates still failing after a fix attempt:"$'\n'"$failures" '{systemMessage: $m}'
  exit 0
fi

{
  echo "Stop gate: project tests FAILED — fix before finishing the turn."
  printf %s "$failures"
} >&2
exit 2
