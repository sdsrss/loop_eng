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

# 73 = EX_CANTCREAT, matching the sysexits vocabulary these scripts already speak
# (64 EX_USAGE, 75 EX_TEMPFAIL, 78 EX_CONFIG).
cannot_write() { # $1 = what, $2 = why
  echo "run-contract: cannot write $1 ($2) — refusing to run (fail closed). results.json and evidence/ ARE the completion record the harness trusts, so a contract whose result cannot be recorded has not been verified. Check permissions and free space under $LOOP_DIR/." >&2
  exit 73
}
mkdir -p "$EVID" 2>/dev/null || cannot_write "$EVID" "mkdir failed"

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
# Human/model-readable failure summary, emitted to stderr after the ledger is
# written. results.json + evidence/ are the machine record, but they are FILES:
# a caller that only sees this process's output (the stop-gate, whose stderr IS
# the block reason fed back to the model; a human running the runner by hand)
# used to get an exit code and nothing else. Accumulated in the criteria loop
# below — the `{ ... } > "$TMP"` group is a group command, not a subshell, so
# these assignments survive it (same reason `ran`/`used_ids` are read after it).
nfail=0
fail_report=""
TMP="$RESULTS.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# Prove BOTH output paths are writable before a single criterion runs. Without
# this the failures were safe only by accident: an unwritable .loop/ made the
# `{ … } > "$TMP"` group's redirect fail, so the criteria loop never executed and
# `ran`/`malformed` were never assigned — the script exited non-zero three lines
# later purely because `set -u` tripped over an unbound variable, printing bash
# internals where a cause belonged. Hoisting those initialisations out of the
# group command (an ordinary cleanup someone will eventually make) would have
# converted a full disk into a false ALL GREEN. An unusable evidence dir was
# quieter still: every criterion's log redirect failed, so PASSING checks were
# reported as failing, with nothing saying why. Fail closed, on purpose, here.
# NB the redirection ORDER: `2>/dev/null` must come BEFORE the probe redirect.
# Redirections are applied left to right, so `: > "$TMP" 2>/dev/null` sets up the
# failing one first and bash reports "Permission denied" on the still-open
# stderr — leaking a raw `run-contract.sh: line NN:` above our own message, which
# is the very noise this check exists to replace. Do not reorder.
: 2>/dev/null > "$TMP" || cannot_write "$RESULTS" "ledger file not creatable"
: 2>/dev/null > "$EVID/.writable" || cannot_write "$EVID" "evidence directory not writable"
rm -f "$EVID/.writable"

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
  lineno=0
  malformed=""
  used_ids="|"
  # `|| [ -n "$id" ]`: read returns non-zero on a final line with no trailing
  # newline but still assigns it; without this the last criterion is silently
  # dropped, and a dropped FAILING criterion yields a false all_green.
  while IFS=$'\t' read -r id desc cmd || [ -n "$id" ]; do
    lineno=$((lineno + 1))
    # CRLF-authored criteria.tsv: read() leaves the line-ending CR on the LAST
    # field (cmd). Left in, `bash -c "true\r"` runs a command whose name ends in
    # CR -> "command not found" (exit 127), so a PASSING check reports a false RED
    # and the loop can never reach ALL GREEN. Strip it BEFORE the shape checks so
    # a CRLF blank-command line classifies exactly like its LF form.
    # (json_str already escapes CR for JSON validity; this fixes the exec path.)
    cmd="${cmd%$'\r'}"
    # Classify every line ONCE, so no criterion can vanish in silence.
    # Skipped without comment (none of these is a criterion): blank lines,
    # whitespace-only lines, and #comments (a leading indent is tolerated —
    # an indented comment was already skipped before, and must not become an
    # error now). CR counts as whitespace, so CRLF blanks skip here too.
    # ANY other line that fails to yield both an id and a command column is
    # MALFORMED: its author wrote it meaning it to be checked. The classic slip
    # is spaces where TABs belong, which parses the whole line into $id and
    # leaves $cmd empty; a leading TAB (empty id) is the mirror image. Both used
    # to hit a bare `continue`, so the contract ran FEWER criteria than it was
    # given and still reported all_green — the vacuous guard below only fires at
    # ZERO runnable criteria, never on a partial parse. Recording the line number
    # is what lets the ledger fail CLOSED on a contract it only partly parsed.
    case "$id$desc$cmd" in
      *[![:space:]]*) : ;;  # carries content — classify it below
      *) continue ;;        # blank or whitespace-only
    esac
    case "${id#"${id%%[![:space:]]*}"}" in \#*) continue ;; esac
    if [ -z "${id:-}" ] || [ -z "${cmd:-}" ]; then
      malformed="$malformed $lineno"
      continue
    fi
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
    if [ "$status" -eq 0 ]; then pass=true; else
      pass=false; overall=1
      nfail=$((nfail + 1))
      # Bounded on purpose: the last 3 lines of this criterion's log, each cut to
      # 200 columns. The stop-gate tails our output into a hook stderr payload,
      # so an unbounded dump (a minified stack trace, a 10k-line test log) would
      # push the actual criterion names out of the model's block reason.
      # Past the 8th failure, drop to ONE evidence line: the stop-gate tails this
      # summary into a 40-line block reason, and 3 lines each put a 10-failure
      # contract at 41 — one line over, costing the header. Worst case is now
      # 1 + 4*min(N,8) + 2*max(N-8,0) lines: 37 at N=10. Beyond that the earliest
      # failures still scroll out; results.json remains the complete record.
      ev_lines=3
      [ "$nfail" -gt 8 ] && ev_lines=1
      ev_tail=$(tail -n "$ev_lines" "$log" 2>/dev/null | cut -c 1-200)
      fail_report="$fail_report
  FAIL [$id] $desc (exit $status)"
      if [ -n "$ev_tail" ]; then
        fail_report="$fail_report
$(printf '%s\n' "$ev_tail" | sed 's/^/    /')"
      fi
    fi
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
  # A PARTLY parsed contract is the same false-green class one step in: some
  # criteria ran, but a line the author wrote never did. Nothing downstream can
  # tell the difference between "3 criteria, all green" and "4 authored, 1
  # silently dropped, the other 3 green" — so force the ledger red and name the
  # lines. Fail closed: "done" must cover the whole contract, not the part of it
  # that happened to parse.
  [ -n "$malformed" ] && overall=1
  if [ "$ran" -eq 0 ]; then
    overall=1
    printf '  "all_green": false,\n'
    printf '  "error": "no runnable criteria in %s (empty, all-comment, or malformed) — vacuous contract fails closed"\n' "$(json_str "$CRIT")"
  else
    [ -n "$malformed" ] && printf '  "malformed_lines": "%s",\n' "$(json_str "${malformed# }")"
    if [ "$overall" -eq 0 ]; then printf '  "all_green": true\n'; else printf '  "all_green": false\n'; fi
  fi
  printf '}\n'
} > "$TMP"
mv "$TMP" "$RESULTS"

# Say what failed, on stderr. The ledger stays the machine record; this is the
# only channel a caller sees without opening files — and for the stop-gate that
# channel IS the block reason handed back to the model, so an empty one costs
# the loop a whole round of rediscovery. Failures only: a green contract stays
# silent so the summary never becomes noise.
if [ -n "$malformed" ]; then
  echo "run-contract: malformed criteria line(s):$malformed in $CRIT — each criterion needs THREE TAB-separated columns (<id>TAB<description>TAB<command>). A line whose columns are separated by SPACES parses as a single field, so that criterion never runs; refusing to report a result for a contract that was only partly parsed (fail closed). Fix the line(s), or comment them out with a leading # if they were never meant to be criteria." >&2
fi
if [ "$overall" -ne 0 ]; then
  if [ "$ran" -eq 0 ]; then
    echo "run-contract: no runnable criteria in $CRIT (empty, all-comment, or malformed) — vacuous contract fails closed; a contract that verifies nothing can never be 'done'. Add <id>TAB<description>TAB<command> lines." >&2
  elif [ "$nfail" -gt 0 ]; then
    # Only when a criterion actually ran and failed. A contract that is red
    # SOLELY because of a malformed line has nfail=0, and "0 of 3 criteria
    # FAILED" would read as a contradiction of the message just above it.
    printf 'run-contract: %d of %d criteria FAILED (ledger: %s, logs: %s/):%s\n' \
      "$nfail" "$ran" "$RESULTS" "$EVID" "$fail_report" >&2
  fi
fi

# Prune stale evidence logs so .loop/evidence/ reflects only the CURRENT contract.
# `used_ids` holds "|id1|id2|...|" for exactly the criteria that ran this pass, and
# each ran criterion wrote "$EVID/<safe_id>.log", so any *.log whose stem is not in
# used_ids belongs to a prior, now-removed criterion. Without this, a repo that
# cycles through many contracts accumulates stale evidence logs forever.
#   - Only files directly under "$EVID" matching *.log are touched — no recursion.
#   - Respects LOOP_ENG_LOOP_DIR via "$EVID" (never a hardcoded .loop/).
#   - Guarded to ran>0: a vacuous/empty contract (ran==0) has no trustworthy
#     current id set, so it never prunes. The hash-lock mismatch (exit 77), the
#     no-sha-tool (exit 77), and the missing-criteria (exit 78) fail-closed paths
#     all `exit` BEFORE the criteria loop, so they never reach here — their armed
#     evidence is left untouched, and none of the fail-closed exits are weakened.
#   - Guarded on malformed too: a partly parsed contract's id set is incomplete
#     by definition, so a dropped line's still-valid evidence log would look
#     stale and be deleted — destroying evidence on the one run that is telling
#     the author their contract is wrong. Same rule as every other fail-closed
#     path: when the parse is not trustworthy, touch nothing.
#   - Fail-open on its own errors: a prune miss must never affect the ledger or the
#     exit code, which are the only things the harness trusts.
if [ "$ran" -gt 0 ] && [ -z "$malformed" ]; then
  for f in "$EVID"/*.log; do
    [ -e "$f" ] || continue           # no-match glob expands to the literal "*.log"
    stem="${f##*/}"; stem="${stem%.log}"
    case "$used_ids" in
      *"|$stem|"*) : ;;               # stem is a current criterion — keep it
      *) rm -f "$f" 2>/dev/null || : ;;  # stale: from a criterion no longer present
    esac
  done
fi
exit "$overall"
