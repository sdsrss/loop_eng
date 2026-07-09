#!/usr/bin/env bash
# loop-eng run-contract — machine-writes the loop's evidence ledger.
#
# Reads .loop/criteria.tsv (one criterion per line: <id>\t<description>\t<command>),
# runs every command, captures full output to .loop/evidence/<id>.log, and writes
# .loop/results.json with per-criterion pass/fail. Exit 0 iff ALL pass.
#
# results.json and evidence/ are the only completion claims the harness trusts.
# The evidence-gate PreToolUse hook denies model writes to them, so a
# "passes": true can never be typed — only produced by actually running the
# command. (Design source: Anthropic's default-FAIL results pattern in
# cwc-long-running-agents.)
set -u

LOOP_DIR="${LOOP_ENG_LOOP_DIR:-.loop}"
CRIT="$LOOP_DIR/criteria.tsv"
RESULTS="$LOOP_DIR/results.json"
EVID="$LOOP_DIR/evidence"

[ -f "$CRIT" ] || { echo "run-contract: $CRIT not found — write the contract first" >&2; exit 78; }
mkdir -p "$EVID"

json_str() { # escape backslash + double quote (TSV lines cannot contain \t or \n)
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

overall=0
TMP="$RESULTS.tmp.$$"
{
  printf '{\n  "generated_by": "run-contract.sh",\n'
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "criteria": [\n'
  first=1
  while IFS=$'\t' read -r id desc cmd; do
    [ -z "${id:-}" ] && continue
    case "$id" in \#*) continue ;; esac
    [ -z "${cmd:-}" ] && continue # malformed line: fewer than 3 columns
    log="$EVID/$id.log"
    status=0
    # </dev/null: without it, a stdin-reading criterion command would consume
    # the remaining criteria lines from the while-read loop (dropped criteria,
    # possibly a false all_green)
    bash -c "$cmd" > "$log" 2>&1 </dev/null || status=$?
    if [ "$status" -eq 0 ]; then pass=true; else pass=false; overall=1; fi
    [ "$first" -eq 0 ] && printf ',\n'
    first=0
    printf '    {"id": "%s", "desc": "%s", "cmd": "%s", "exit": %d, "passes": %s, "evidence": "%s"}' \
      "$(json_str "$id")" "$(json_str "$desc")" "$(json_str "$cmd")" \
      "$status" "$pass" "$(json_str "$log")"
  done < "$CRIT"
  printf '\n  ],\n'
  if [ "$overall" -eq 0 ]; then printf '  "all_green": true\n'; else printf '  "all_green": false\n'; fi
  printf '}\n'
} > "$TMP"
mv "$TMP" "$RESULTS"
exit "$overall"
