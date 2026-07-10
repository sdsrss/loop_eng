# Changelog

## 0.3.0 — 2026-07-10

Descriptions-only release: changes when Claude Code auto-invokes the plugin,
not what the loops do. No user action required; to restore the old routing
behavior, reinstall v0.2.3.

### Changed
- Rewrote the LLM-visible descriptions of `/autoloop`, `/polish`, and the
  `loop-eng` skill from feature-driven (mechanism jargon) to scenario-driven:
  each now front-loads "Use when" trigger conditions with natural user phrases
  (bilingual EN/中文, e.g. "keep going until tests pass", 挂机/无人值守/打磨),
  and names its differentiator (/polish vs one-shot code review; the skill vs
  prompt-only goal trackers). Raises Claude Code's auto-invocation recall on
  genuine loop intent; no behavior change — hooks, scripts, and agents untouched.

## 0.2.3 — 2026-07-10

Three false-verdict fixes in the contract runner, found by end-to-end testing of
the real /autoloop flow. All are bugfixes restoring intended behavior — a
contract must fail closed when it verifies nothing, must never emit invalid
evidence, and must not fail a criterion for its name.

### Fixed
- `run-contract.sh`: a `criteria.tsv` with ZERO runnable criteria (empty,
  all-comment, or every line malformed) produced `all_green: true` / exit 0 — a
  false green that let the stop-gate lift on a vacuous contract, defeating the
  whole "done is a machine-verified, multi-criterion fact" guarantee. It now
  fails CLOSED (`all_green: false`, exit 1, `error` naming the vacuous contract).
  `arm-contract.sh` additionally warns at arm time so the mistake surfaces
  immediately, not at the first stop.
- `run-contract.sh`: a criterion field containing a TAB (a 4+ column line, or a
  CRLF-authored `criteria.tsv` leaving a trailing CR) emitted a raw control
  character into `results.json`, making it invalid JSON — the checker agent,
  humans, and any tooling that parses the evidence ledger would choke. `json_str`
  now escapes TAB and CR — and replaces any other residual C0 control byte with a
  space — so `results.json` is valid JSON for any field byte content, not just the
  common TAB/CRLF vectors. It is also pure-bash, so it stays portable and drops a
  per-field `sed` subprocess.
- `run-contract.sh`: a criterion whose `id` contained `/` (e.g. `lint/eslint`)
  produced a false RED — the evidence log path pointed at a non-existent nested
  dir, the redirect failed, the command never ran, and a passing criterion
  reported `passes: false`, so the loop could never go green. The id is now
  sanitized for the evidence FILENAME only (the JSON keeps the real id); this
  also blocks a `..` id from escaping `.loop/evidence/`.
- `unattended-autoloop.sh`: a non-numeric `LOOP_ENG_MAX_MINUTES` (e.g. a typo'd
  scheduler env var) crashed the driver immediately (`xyz: unbound variable` in
  `$(( ))` under `set -u`), and a non-numeric `max-sessions` arg silently
  disabled the session cap while spamming `[: integer expression expected` every
  iteration. Both numeric knobs (plus `LOOP_ENG_LIMIT_WAIT_MIN`) are now
  validated up front — an unattended entry point WARNS and falls back to the
  default rather than aborting or misbehaving on a bad value. Validated values
  are also normalized to base-10, so a leading-zero knob like `08`/`09` no longer
  crashes bash arithmetic (`$((08*60))` → "value too great for base").
- `unattended-polish.sh`: same guard for `LOOP_ENG_MAX_MINUTES`, which otherwise
  reached `timeout "${MAX_MINUTES}m"` and failed opaquely on a non-numeric value.

- `commands/autoloop.md`: on `ALL GREEN`, Step 3 told the orchestrator to cite
  `.loop/results.json (all_green: true)` as machine proof — but nothing in the
  loop refreshes that file after the fix (builder and checker run the raw verify
  commands, not `run-contract.sh`; the ledger is refreshed lazily by the Stop
  hook only at the actual stop attempt). Reading it to cite it therefore showed
  the stale pre-fix `all_green: false`, contradicting the report. Step 3 now
  runs `run-contract.sh` to refresh the ledger before citing it. (Found by an
  end-to-end `/autoloop` run: the checker itself flagged the stale ledger.)

### Docs
- `SKILL.md`: the `/autoloop` and `/polish` pointers referenced
  `.claude/commands/*.md` — the gitignored local dogfood copy, which does not
  exist in an installed plugin. Now point to the shipped `commands/*.md`.

## 0.2.2 — 2026-07-10

Closes the last open item from the 0.2.0 review: the Stop-hook timeout could
let an unverified contract stop.

### Fixed
- `stop-gate.sh`: the contract now runs under an internal budget
  (`LOOP_ENG_GATE_TIMEOUT`, default 100s) kept below the 120s Stop-hook timeout
  in `hooks.json`. Previously, a `criteria.tsv` slower than 120s would let
  Claude Code kill the hook — and a killed Stop hook does not reliably block, so
  the session could stop with the contract UNVERIFIED. If the run overruns the
  budget the gate now BLOCKS deliberately (fail closed, exit 2) with a message
  telling you to make criteria.tsv a faster subset, instead of gambling on the
  platform's kill behavior. Falls back to an unbounded run (with a warning) only
  when neither `timeout` nor `gtimeout` is available.

### Docs
- `contract.md` documents the Stop-hook time budget so authors keep the
  per-round `criteria.tsv` fast and leave the slow full suite for the final round.

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
