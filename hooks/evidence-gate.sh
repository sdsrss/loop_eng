#!/usr/bin/env bash
# loop-eng evidence-gate — PreToolUse hook.
#
# .loop/results.json and .loop/evidence/ are machine-written by run-contract.sh;
# .loop/criteria.tsv is written once at contract time and fixed while the loop
# is armed (.loop/active); after a loop ends the next contract may rewrite it.
# This hook denies model writes to them (exit 2, stderr fed back to the model),
# so a "passes": true can never be typed into existence — only produced by the
# runner actually executing the contract's commands. Weakening the contract by
# rewriting an armed criteria.tsv is likewise mechanically blocked, not just
# forbidden in prompt text.
#
# The contract lock is armed-scoped, not permanent: a model that removes
# .loop/active to unlock criteria.tsv has already escaped the stop-gate the
# same way — the gate guards against drift INSIDE an armed loop, not against
# adversarial disarming; red lines + human review of the diff cover the rest.
#
# Bash coverage is best-effort by design: a conservative pattern (redirect /
# tee / mv / cp / sed -i / truncate / rm targeting a protected path) catches
# the plausible accidents; the red lines in the command prompts remain the
# second layer. Fail-open on missing parser or unparseable input — the gate
# must never brick a session.
#
# Escape hatch (humans, not models): LOOP_ENG_DISABLE_EVIDENCE_GATE=1.
set -u

if [ "${LOOP_ENG_DISABLE_EVIDENCE_GATE:-0}" = "1" ]; then
  cat > /dev/null
  exit 0
fi

INPUT=$(cat)

TOOL=""; FILE=""; CMD=""
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL=""
  # NotebookEdit carries its target in .tool_input.notebook_path, every other
  # write tool in .tool_input.file_path — fall through so NotebookEdit is not a
  # blind spot into the ledger.
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || FILE=""
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
# file_path for Write/Edit/MultiEdit; notebook_path for NotebookEdit.
fp = ti.get("file_path") or ti.get("notebook_path") or ""
print("TOOL=%s" % shlex.quote(str(d.get("tool_name", ""))))
print("FILE=%s" % shlex.quote(str(fp)))
print("CMD=%s" % shlex.quote(str(ti.get("command", ""))))
' 2>/dev/null) || PARSED=""
  eval "$PARSED"
else
  echo "loop-eng evidence-gate: no jq or python3 available; gate inactive for this call." >&2
  exit 0
fi

deny() {
  # Name the runner by a path that actually exists where the model runs: in a
  # marketplace install the plugin lives in the plugin cache, not in the user's
  # project, so a project-relative skills/... path would send the model to a
  # file that isn't there. Print the real absolute path when the platform gave
  # us CLAUDE_PLUGIN_ROOT; otherwise a placeholder the human can resolve.
  local runner="${CLAUDE_PLUGIN_ROOT:-<loop-eng plugin root>}/skills/loop-eng/scripts/run-contract.sh"
  {
    echo "loop-eng evidence-gate DENIED: $1"
    echo ".loop/results.json and .loop/evidence/ are machine-written evidence."
    echo "let the stop-gate run the contract on your next stop attempt, or run"
    echo "the plugin's run-contract.sh ($runner)"
    echo "yourself instead of writing claims. Weakening a check to pass it is a"
    echo "red line."
    echo "(If a Bash command only NAMES a guarded path — in a string, comment,"
    echo "subshell, or sed script — rather than writing it, this is a conservative"
    echo "false match: reword the command, or use the escape hatch below.)"
    echo "(Human escape hatch: LOOP_ENG_DISABLE_EVIDENCE_GATE=1.)"
  } >&2
  exit 2
}

case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit)
    case "$FILE" in
      */.loop/results.json|.loop/results.json)
        deny "the evidence ledger .loop/results.json" ;;
      */.loop/evidence/*|.loop/evidence/*)
        deny "raw evidence under .loop/evidence/" ;;
      */.loop/criteria.tsv|.loop/criteria.tsv)
        # Locked while the loop is armed: the sibling .loop/active next to this
        # criteria.tsv must exist. Derive the marker from $FILE's dir so relative
        # and absolute paths both resolve sensibly. Do NOT require the file to
        # pre-exist — a legacy (verify.sh) loop has no criteria.tsv, and CREATING
        # one while armed hijacks the stop-gate (which prefers criteria.tsv over
        # verify.sh), so the create must be denied as well as the overwrite.
        if [ -e "$(dirname "$FILE")/active" ]; then
          deny "the armed contract .loop/criteria.tsv (loop is active)"
        fi ;;
      */.loop/backlog.md|.loop/backlog.md)
        # A MACHINE-TICKED backlog only. A line written
        # `- [ ] <item> | verify: <cmd>` is ticked by run-contract from that
        # command's exit status, so a model write to the file is the completion
        # claim the ledger exists to produce, typed instead of earned — the same
        # thing results.json is guarded against. A backlog with NO verify
        # commands keeps the older model-ticked contract and stays writable:
        # opting in is what locks the file, so no existing loop changes under
        # anyone. Reads the file that is there now, which is also what makes
        # "remove the verify commands, then write freely" a denied write.
        if [ -e "$(dirname "$FILE")/active" ] \
           && grep -q '|[[:space:]]*verify:' "$FILE" 2>/dev/null; then
          deny "the machine-ticked backlog .loop/backlog.md (loop is active).
Its \`| verify:\` lines are ticked by run-contract.sh from the verify command's
exit status — that is what makes a ticked box a fact rather than a claim. Make
the command pass; the next stop attempt ticks the box for you."
        fi ;;
      */.loop/criteria.sha256|.loop/criteria.sha256)
        # The hash-lock: writing it to match a weakened criteria.tsv would defeat
        # run-contract's tamper check, so lock it while armed too — create as well
        # as overwrite (same reasoning as criteria.tsv above).
        if [ -e "$(dirname "$FILE")/active" ]; then
          deny "the armed contract hash-lock .loop/criteria.sha256 (loop is active)"
        fi ;;
    esac
    ;;
  Bash)
    # Strip `->` arrows before matching: a literal `->` (e.g. in an echoed
    # message "logs -> $(ls .loop/evidence/)") has its `>` read as a redirect
    # verb by the regex below, spuriously denying a command that only MENTIONS a
    # guarded path. No real shell redirect ever contains `->`, so blanking it is
    # provably true-positive-preserving (every `>`/`>>`/`2>` redirect survives).
    # This is the ONLY normalization: the match stays deliberately conservative —
    # a command that merely names a guarded path in a string/subshell/sed-script
    # is still denied (over-blocking, never under-blocking), because the real
    # integrity guarantee is run-contract's hash re-derivation, not this regex.
    SCAN=$(printf '%s' "$CMD" | sed 's/->/ /g')
    # results.json + evidence/ are the machine ledger: always protected.
    #
    # Three shapes the first version of this pattern let through, each of them
    # an ordinary typing habit rather than an evasion:
    #   `rm -rf .loop/evidence`       — the trailing slash was REQUIRED, so the
    #                                   plain directory name (how anyone writes
    #                                   an rm) matched nothing. Now the name
    #                                   matches when followed by `/`, by end of
    #                                   line, or by anything that cannot be part
    #                                   of a filename. NOT `\b`: that counts `-`
    #                                   and `.` as boundaries, which newly denied
    #                                   `.loop/evidence-notes.md` and
    #                                   `.loop/evidence.bak` — sibling files that
    #                                   are not the ledger.
    #   `echo x >| .loop/results.json` — `>|` is the noclobber override, i.e.
    #                                   deliberately "overwrite anyway", and the
    #                                   verb group stopped at `>>?`.
    #   `echo x > .loop//results.json` — a doubled slash is the same path to
    #                                   every OS and matched nothing. `/+`.
    # Still out of scope, and stated in the header: indirection that hides the
    # path from the text entirely (`F=.loop/results.json; echo x > $F`). No
    # regex over a command string can see through a variable; the integrity
    # guarantee for that class is run-contract's hash re-derivation.
    if printf '%s' "$SCAN" | grep -qE '(>>?\|?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/+(results\.json|evidence(/|$|[^A-Za-z0-9._-]))'; then
      deny "a Bash command writing to the .loop evidence ledger"
    fi
    # criteria.tsv + its hash-lock are locked only while the loop is armed
    # (.loop/active in cwd — Bash commands run in the project cwd, so the
    # cwd-relative check suffices). This regex is best-effort (see header): the
    # real integrity guarantee is run-contract's hash re-derivation, which no
    # Bash verb can slip past.
    if [ -e .loop/active ] && printf '%s' "$SCAN" | grep -qE '(>>?\|?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/+criteria\.(tsv|sha256)'; then
      # Common legitimate case: a wrap-up that removes .loop/active AND
      # .loop/criteria.sha256 in ONE command is denied because the gate scans the
      # whole command string while active still exists. Advise splitting it.
      deny "a Bash command writing to the armed contract .loop/criteria.tsv or its hash-lock.
If this is a wrap-up removing both .loop/active and .loop/criteria.sha256 in one
command, split it into two Bash calls: remove .loop/active first (that disarms
the loop), then remove .loop/criteria.sha256 in a second call."
    fi
    # The machine-ticked backlog, while armed — same reasoning as the Write/Edit
    # branch above, and gated on the same `| verify:` opt-in, so a backlog
    # without verify commands is untouched by this rule.
    if [ -e .loop/active ] && grep -q '|[[:space:]]*verify:' .loop/backlog.md 2>/dev/null \
       && printf '%s' "$SCAN" | grep -qE '(>>?\|?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/+backlog\.md'; then
      deny "a Bash command writing to the machine-ticked backlog .loop/backlog.md.
Its \`| verify:\` lines are ticked by run-contract.sh from the verify command's
exit status. Make the command pass; the next stop attempt ticks the box."
    fi
    # The whole directory, while armed. Everything above guards one file inside
    # .loop/; `rm -rf .loop` takes the stop-gate's marker, the hash-lock, the
    # ledger and the evidence in a single command, so the loop is disarmed and
    # every check above is moot. It is not an adversarial shape — README offers
    # exactly this line as the human cleanup command — which makes it the most
    # likely way an ordinary wrap-up ends a loop without verifying it.
    #
    # The boundary is the same one the ledger pattern above had to learn: the
    # name matches when followed by `/` and nothing more, by end of line, or by
    # a byte that cannot continue a filename. NOT `\b`, and NOT a bare `.loop`
    # prefix — a SUBPATH must still go through. `.loop/state.md` is the
    # orchestrator's own scratch file and has never been guarded, and
    # `.loopback` is a different directory that merely shares five characters.
    #
    # `rm` and `mv` only. A redirect or `tee` cannot destroy a directory, and
    # `cp` onto one does not disarm anything; the verbs here are the two that
    # make .loop stop existing where the gate looks for it.
    if [ -e .loop/active ] && printf '%s' "$SCAN" | grep -qE '(\brm\b|\bmv\b)[^|;&]*\.loop/*([^A-Za-z0-9._/-]|$)'; then
      deny "a Bash command removing or moving the whole .loop directory while the loop is ARMED.
That single command disarms the stop-gate, drops the hash-lock and destroys the
evidence ledger at once — the loop would end unverified with nothing left to
show for it. If the loop is genuinely over, disarm first and clean up after:
run \`rm .loop/active\` in one Bash call, then \`rm -rf .loop\` in a second."
    fi
    ;;
esac

exit 0
