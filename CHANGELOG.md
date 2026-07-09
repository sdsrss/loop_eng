# Changelog

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
