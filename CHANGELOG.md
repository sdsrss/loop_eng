# Changelog

## 0.2.1 — 2026-07-10

Hardening release, from a code review of 0.2.0. Two things: a silent false-green
in the contract runner is fixed, and the armed-contract lock gains a mechanical
hash-lock so weakening a check can no longer pass quietly.

### Fixed
- `run-contract.sh`: a `criteria.tsv` whose last line had no trailing newline
  silently dropped that criterion — and a dropped FAILING criterion produced a
  false `all_green: true` / exit 0, the exact outcome the gate exists to prevent.
  The read loop now processes the final unterminated line (`|| [ -n "$id" ]`),
  with a no-trailing-newline regression test.
- `run-contract.sh`: the `results.json.tmp.$$` scratch file is now trap-cleaned
  on exit (was orphaned on a mid-write kill).
- `stop-gate.sh`: the block counter is cleared when the platform block ceiling
  force-allows a stop, so a re-armed loop that inherits a stale `.loop/gate-count`
  is no longer instantly inert.

### Added
- Contract hash-lock. `arm-contract.sh` (new, replaces a bare `touch
  .loop/active`) pins `sha256(criteria.tsv)` into `.loop/criteria.sha256` at arm
  time; `run-contract.sh` re-derives that hash on every stop attempt and fails
  CLOSED (exit 77, `all_green: false`, tamper reason) if the live file no longer
  matches. Because it checks the file's *contents*, no write path can slip past —
  including Bash verbs the evidence-gate regex can't see (`python3`, `perl -i`,
  `dd`, `cd .loop && …`). `evidence-gate.sh` also locks `.loop/criteria.sha256`
  while armed; `stop-gate.sh` clears it when it lifts the gate.

### Security scope (honest)
- The Write/Edit/MultiEdit tool path to the ledger and armed contract is
  mechanically closed. The Bash path is best-effort regex PLUS the hash-lock:
  post-arm drift and single-verb weakening now fail closed and loud. A fully
  adversarial model with arbitrary Bash that rewrites BOTH `criteria.tsv` and
  `criteria.sha256` to a matching weakened pair remains out of scope — the red
  lines in the command prompts and human review of the diff cover that residual.
  Note `.loop/` is gitignored, so a weakened contract does not surface in `git diff`.
- The stop-gate runs the full `criteria.tsv` inside the 120s Stop-hook timeout;
  keep `criteria.tsv` a FAST subset (the contract already says so) — a criteria
  set slower than 120s risks the hook being killed.

## 0.2.0 — 2026-07-09

New default behavior (opt-out available): the evidence-gate PreToolUse hook
now denies model writes to `.loop/results.json`, `.loop/evidence/`, and an
armed `.loop/criteria.tsv`. Loops behave as before otherwise; if the gate
gets in your way, set `LOOP_ENG_DISABLE_EVIDENCE_GATE=1` (the deny message
says exactly this). Pre-0.2 loops using `.loop/verify.sh` keep working —
the stop-gate falls back to it when `criteria.tsv` is absent. The PreToolUse
gate is registered for Write/Edit/MultiEdit/NotebookEdit/Bash and thus runs
(as a fail-open no-op) on those tool calls in any project where the plugin's
hooks load — it only ever denies writes targeting `.loop/`-protected paths.
The contract lock is armed-scoped: `.loop/criteria.tsv` is immutable while
`.loop/active` exists and rewritable between loops.

### Added
- `run-contract.sh`: executes `.loop/criteria.tsv`, machine-writes
  `.loop/results.json` + per-criterion `.loop/evidence/<id>.log`.
- `evidence-gate.sh` (PreToolUse): completion evidence can be produced only
  by running the contract, never typed.
- `unattended-autoloop.sh`: cross-session fresh-context driver — one
  backlog item per `claude -p` session, commit-keyed circuit breaker
  (2 no-commit sessions → stop), session cap, wall-clock budget,
  usage-limit wait/retry.
- /polish impact scoping: findings classed
  `correctness|requirement|optional`; optional is reported, never auto-fixed.
- Test suite: `tests/run-all.sh` (sandboxed; bash -n + shellcheck + e2e).

### Fixed
- `unattended-polish.sh` never recorded non-zero claude exit codes
  (`set -e` killed the script before the bookkeeping line); now captured
  and passed through, with rate-limited runs exiting 75.

### Changed
- Stop gate prefers `criteria.tsv` (via `run-contract.sh`) over legacy
  `verify.sh`; documents the platform's 8-consecutive-blocks force-allow
  (loop-eng's ceiling of 3 stays under it).
- `/autoloop` writes `criteria.tsv` instead of `verify.sh`; backlog items
  use `- [ ]` checkboxes; `lessons.md` entries use one fixed format.

## 0.1.0 — 2026-07-09

Initial release: /autoloop, /polish, stop-gate, unattended polish runner.
