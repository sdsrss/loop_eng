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

# LOOP_ENG_LOOP_DIR is a TEST-ONLY knob (the plugin's own suite sandboxes with
# it). The stop-gate and evidence-gate are fixed to .loop/ — pointing a real
# loop at a custom dir silently removes it from both hooks' protection.
LOOP_DIR="${LOOP_ENG_LOOP_DIR:-.loop}"
CRIT="$LOOP_DIR/criteria.tsv"
RESULTS="$LOOP_DIR/results.json"
EVID="$LOOP_DIR/evidence"
ACTIVE="$LOOP_DIR/active"
SHA_LOCK="$LOOP_DIR/criteria.sha256"

[ -f "$CRIT" ] || { echo "run-contract: $CRIT not found — write the contract first" >&2; exit 78; }
mkdir -p "$EVID"

# Portable SHA-256 of a file -> stdout (empty if no hashing tool is available).
loop_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

json_str() { # escape for a JSON string: backslash, double quote, and the control
  # chars that survive TSV parsing — a 4+column line leaves a TAB inside cmd, and
  # a CRLF-authored criteria.tsv leaves a trailing CR; unescaped they make
  # results.json invalid JSON (control chars must be \-escaped). Pure-bash so it
  # stays portable (no GNU-sed \t) and cheap (no subprocess per field).
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first
  s="${s//\"/\\\"}"    # double quote
  s="${s//$'\t'/\\t}"  # tab
  s="${s//$'\r'/\\r}"  # carriage return
  # Any other C0 control byte (ESC / FF / VT / BS / …) is illegal raw in a JSON
  # string too; escaping only TAB/CR would still leave results.json invalid for
  # those. LF can't occur (read splits on it) and NUL can't live in a bash var,
  # so replace the residual C0 set with a space — results.json is then valid
  # JSON for ANY field byte content, not just the common TAB/CRLF vectors.
  # NB: the $'\xHH' ANSI-C escapes and this bracket-range pattern substitution
  # are CI-verified on stock macOS bash 3.2 (the test-bash32 job) — do not
  # "portability-rewrite" it speculatively; the CI leg is the ground truth.
  s="${s//[$'\x01'-$'\x08'$'\x0b'$'\x0c'$'\x0e'-$'\x1f']/ }"
  printf '%s' "$s"
}

overall=0
TMP="$RESULTS.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# Contract lock (hash-lock): while the loop is armed, criteria.tsv is pinned to
# the SHA-256 recorded by arm-contract.sh. If the live file no longer matches,
# the contract has been weakened out from under the loop — fail CLOSED (write a
# tampered ledger and exit 77) rather than executing the altered commands. This
# catches every write path — including Bash verbs the evidence-gate regex can't
# see (python3, perl -i, dd, `cd .loop && …`) — because it re-derives truth from
# the file's contents, not from which tool touched it. A fully adversarial model
# that rewrites BOTH criteria.tsv and criteria.sha256 to a matching weakened pair
# remains out of scope (red lines + human diff review cover that residual); what
# the lock guarantees is that post-arm drift can never pass SILENTLY.
if [ -f "$ACTIVE" ] && [ -f "$SHA_LOCK" ]; then
  armed_hash=$(cut -d' ' -f1 < "$SHA_LOCK")
  live_hash=$(loop_sha256 "$CRIT")
  if [ -z "$live_hash" ]; then
    echo "run-contract: criteria.sha256 present but no SHA-256 tool to verify it; refusing to run (fail closed)." >&2
    {
      printf '{\n  "generated_by": "run-contract.sh",\n  "all_green": false,\n'
      printf '  "error": "contract locked but integrity could not be verified (no sha256 tool)"\n}\n'
    } > "$TMP"
    mv "$TMP" "$RESULTS"
    exit 77
  fi
  if [ "$armed_hash" != "$live_hash" ]; then
    echo "run-contract: criteria.tsv does not match the armed contract hash — the contract was altered while the loop is active. Refusing to run (fail closed)." >&2
    {
      printf '{\n  "generated_by": "run-contract.sh",\n  "all_green": false,\n'
      printf '  "error": "contract tampered: criteria.tsv changed after arm (armed %s, live %s)"\n}\n' \
        "$(json_str "$armed_hash")" "$(json_str "$live_hash")"
    } > "$TMP"
    mv "$TMP" "$RESULTS"
    exit 77
  fi
fi
{
  printf '{\n  "generated_by": "run-contract.sh",\n'
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "criteria": [\n'
  first=1
  ran=0
  used_ids="|"
  # `|| [ -n "$id" ]`: read returns non-zero on a final line with no trailing
  # newline but still assigns it; without this the last criterion is silently
  # dropped, and a dropped FAILING criterion yields a false all_green.
  while IFS=$'\t' read -r id desc cmd || [ -n "$id" ]; do
    [ -z "${id:-}" ] && continue
    case "$id" in \#*) continue ;; esac
    # CRLF-authored criteria.tsv: read() leaves the line-ending CR on the LAST
    # field (cmd). Left in, `bash -c "true\r"` runs a command whose name ends in
    # CR -> "command not found" (exit 127), so a PASSING check reports a false RED
    # and the loop can never reach ALL GREEN. Strip it BEFORE the empty-check so a
    # CRLF blank-command line collapses to malformed, exactly like its LF form.
    # (json_str already escapes CR for JSON validity; this fixes the exec path.)
    cmd="${cmd%$'\r'}"
    [ -z "${cmd:-}" ] && continue # malformed line: fewer than 3 columns
    # Sanitize the id for the evidence FILENAME only — the JSON keeps the real id.
    # A '/' in the id would point the log at a non-existent nested dir, so the
    # redirect fails, the command never runs, and a PASSING criterion reports a
    # false RED (loop can never go green). '..' would also escape .loop/evidence/.
    safe_id="${id//[^A-Za-z0-9._-]/_}"
    # Two distinct ids can sanitize to the same filename ('a/b' and 'a:b' both
    # become a_b): without disambiguation the later criterion's log silently
    # overwrites the earlier one's and results.json cites one path twice —
    # pass/fail stays correct but the evidence is misattributed. Suffix repeats
    # (a_b, a_b.2, a_b.3, …); plain-string probe, bash 3.2-safe.
    case "$used_ids" in
      *"|$safe_id|"*)
        n=2
        while case "$used_ids" in *"|$safe_id.$n|"*) true ;; *) false ;; esac; do
          n=$((n + 1))
        done
        safe_id="$safe_id.$n" ;;
    esac
    used_ids="$used_ids$safe_id|"
    log="$EVID/$safe_id.log"
    status=0
    # </dev/null: without it, a stdin-reading criterion command would consume
    # the remaining criteria lines from the while-read loop (dropped criteria,
    # possibly a false all_green)
    bash -c "$cmd" > "$log" 2>&1 </dev/null || status=$?
    if [ "$status" -eq 0 ]; then pass=true; else pass=false; overall=1; fi
    ran=$((ran + 1))
    [ "$first" -eq 0 ] && printf ',\n'
    first=0
    printf '    {"id": "%s", "desc": "%s", "cmd": "%s", "exit": %d, "passes": %s, "evidence": "%s"}' \
      "$(json_str "$id")" "$(json_str "$desc")" "$(json_str "$cmd")" \
      "$status" "$pass" "$(json_str "$log")"
  done < "$CRIT"
  printf '\n  ],\n'
  # A contract with ZERO runnable criteria (empty, all-comment, or every line
  # malformed) is vacuous — treat it as a FAIL, never a silent all_green. This is
  # the same false-green class the hash-lock guards against: "done" must be a
  # verified fact, and nothing was verified. Fail closed so the stop-gate blocks.
  if [ "$ran" -eq 0 ]; then
    overall=1
    printf '  "all_green": false,\n'
    printf '  "error": "no runnable criteria in %s (empty, all-comment, or malformed) — vacuous contract fails closed"\n' "$(json_str "$CRIT")"
  elif [ "$overall" -eq 0 ]; then printf '  "all_green": true\n'; else printf '  "all_green": false\n'; fi
  printf '}\n'
} > "$TMP"
mv "$TMP" "$RESULTS"
exit "$overall"
