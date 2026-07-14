# Changelog

## 0.5.0 — 2026-07-14

The full audit-driven roadmap batch (21/21 items from
`docs/optimization-roadmap-2026-07-14.md`, derived from
`docs/audit-report-v0.4.1-2026-07-14.md`): mechanism fixes, /autoloop prompt
revisions, CI on ubuntu+macOS, a live marketplace-install verification, and a
release checklist (`RELEASING.md`). No breaking changes.

**Upgrade note**: no action required — no default behavior changes for
existing loops. After updating the plugin, run `/reload-plugins` (or start a
fresh session): an in-place install/update is INERT in the running session
(commands unresolved AND hooks not firing — verified live 2026-07-14). Revert
path: reinstall v0.4.1.

### Verified (closes audit H2/N1 — the enforcement layer now has live mileage)
- Live-install smoke (`RELEASING.md` §1) PASSED 2026-07-14 against
  main @ c1c6aed (plugin cache labeled 0.4.1). Findings, all expected-or-fixed:
  - Hooks/commands require `/reload-plugins` (or a fresh session): in the
    pre-reload session the install is inert — a hand-written
    `.loop/results.json` went through and no command resolved.
  - Post-reload, evidence-gate DENIED the same write, naming the real
    plugin-cache runner path (P5 fix observed live).
  - stop-gate blocked stops 1/3 and 2/3 on a red contract and machine-rewrote
    the hand-written ledger to `all_green: false` on the first stop attempt.
  - `/loop-eng:autoloop` (commands are namespace-prefixed) ran a full loop:
    legitimate close-out of the stale red contract via stop rule 6 + ordered
    two-command disarm (P1 observed live), dirty-tree precondition + baseline
    ref (P2 observed live), arm via expanded `${CLAUDE_PLUGIN_ROOT}`,
    builder/checker round, ALL GREEN with machine ledger, free stop after.

### Fixed
- `unattended-autoloop.sh`: each `claude -p` session now runs under
  `timeout -k 30 <remaining-wall-clock-budget>` (with the stop-gate's
  timeout/gtimeout fallback and a loud warning when neither exists). Previously
  `LOOP_ENG_MAX_MINUTES` was only checked BETWEEN sessions, so a single hung
  session (network stall, wedged tool) blocked the driver indefinitely — under
  a systemd oneshot unit, potentially for days. A timed-out session (exit 124)
  is named in the driver log and counts toward the no-progress breaker.
  (audit N2)
- `install-timer.sh`: the claude CLI is now resolved to an absolute path at
  INSTALL time (honoring `LOOP_ENG_CLAUDE_BIN`) and pinned into the unit via
  `Environment=LOOP_ENG_CLAUDE_BIN=<abs>`; an unresolvable claude dies at
  install. Previously the unit's hardcoded `PATH` could simply not contain
  claude (nvm / custom npm prefix), so the runner failed with exit 127 at first
  trigger with the error only in cron.log — the "installed but silently never
  runs" trap this script exists to kill. A claude path containing whitespace is
  refused like the repo/plugin paths. (audit N3)
- `unattended-autoloop.sh`: a backlog file deleted mid-run made `count_pending`
  return an empty string, which silently skipped the "backlog empty" stop (the
  `[ "" -eq 0 ]` error is swallowed by `if`) and kept launching sessions against
  a missing backlog; it now counts as 0 pending and the driver stops cleanly.
  (audit N4)
- `unattended-{polish,autoloop}.sh`: `LOOP_ENG_MAX_MINUTES=0` passed the digit
  check but `timeout 0m` DISABLES the timeout (GNU semantics) — the opposite of
  a budget knob's lowest value; 0 now warns and falls back to the default.
  (audit L7)
- `stop-gate.sh`: the block-ceiling message now includes the manual disarm
  command (`rm .loop/active`) — reaching the ceiling usually means the
  orchestrator failed to disarm, and without it every later stop attempt in the
  session eats another 3 blocks. (audit M5)

### Changed (prompt revisions, /autoloop orchestration text)
- `commands/autoloop.md` Wrap-up: disarming is now TWO ordered Bash commands
  (`rm -f .loop/active .loop/gate-count`, then `rm -f .loop/criteria.sha256`).
  The previous "remove all three" instruction, executed as one command while
  armed, was denied by the plugin's own evidence-gate (sandbox-proven exit 2)
  with a misleading "weakening a check" message — the model wasted a deny
  round-trip on a legitimate step. (audit P1)
- `commands/autoloop.md` Step 0: added preconditions — a clean tree (dirty
  trees conflate the user's uncommitted work into the final diff) and a
  recorded baseline ref (`git rev-parse HEAD` into `.loop/state.md`); Step 3's
  final diff now cites `git diff <baseline>..HEAD` instead of the unrecorded
  "pre-loop commit". Aligns /autoloop with /polish Phase 0. (audit P2)
- `commands/autoloop.md` arming: when dogfooding this repo via `.claude/`
  (`${CLAUDE_PLUGIN_ROOT}` undefined), use the local
  `.claude/skills/loop-eng/scripts/arm-contract.sh` rather than silently
  falling back to `touch .loop/active` — the fallback loses the hash-lock, so
  dogfood loops were running a degraded contract without noticing. (audit P3)
- `hooks/evidence-gate.sh`: the deny message now names the run-contract.sh
  runner by `$CLAUDE_PLUGIN_ROOT/...` (real absolute path when the platform
  provides it, an explicit placeholder otherwise) instead of a
  project-relative `skills/...` path that does not exist in a user project
  under a marketplace install. (audit P5)

### Added
- CI (`.github/workflows/test.yml`): `bash tests/run-all.sh` on
  ubuntu-latest + macos-latest for every push to main / PR. The project's own
  philosophy applied to itself — a push's "done" is now a machine-verified
  fact, not a human remembering to run the suite. macOS installs brew bash
  (stock 3.2 is too old for the unattended drivers) + shellcheck. (audit H3)

### Docs
- README scope notes (stop-gate section): one loop per repo at a time
  (concurrent arming overwrites the hash-lock → tamper fail-closed) (audit
  M6); the stop-gate guards /autoloop only — /polish has no mechanism-layer
  completion gate (also noted in SKILL.md); `LOOP_ENG_LOOP_DIR` declared
  test-only, with matching header comments in arm-contract.sh /
  run-contract.sh — the hooks are fixed to `.loop/`, so a custom dir silently
  disarms them (audit M3); ledger backup via `cat > dest` (the gate's Bash
  pattern can't tell copy direction) (audit L1).
- README safety-model table: new row naming test/build output as untrusted
  text — checker reports are forwarded verbatim by design, and
  prompt-injection riding in tool output is a residual covered by red lines +
  human diff review.
- README unattended runs: systemd timer pair promoted to the preferred
  scheduling path; cron demoted to the no-systemd fallback (audit N5).
- Test stub portability: the autoloop stub's progress filename is now
  `$$`-unique instead of `date +%s%N` (BSD date prints a literal N — a
  same-second collision would make an empty commit and a flaky breaker count
  on macOS CI).

### Dogfood
- `.claude/settings.json` (untracked): registered the evidence-gate PreToolUse
  hook and aligned hook timeouts with `hooks/hooks.json` (Stop 120s — the
  previous unset timeout defaulted below the gate's 100s internal budget;
  PreToolUse 30s). The audit found the evidence-gate had ZERO live mileage:
  never marketplace-installed, and the dogfood settings registered only the
  Stop hook. (audit N1)
- `scripts/sync-local.sh`: after syncing, warns if `.claude/settings.json`
  does not register stop-gate.sh or evidence-gate.sh — synced-but-unregistered
  hooks mean the dogfood repo exercises only part of the enforcement layer.

### Tests
- New `tests/test-hooks-json.sh` (+12): hooks.json must parse and carry the
  structural contract — Stop → stop-gate.sh via CLAUDE_PLUGIN_ROOT with a
  timeout above the gate's internal budget (cross-checked against the
  LOOP_ENG_GATE_TIMEOUT default in stop-gate.sh); PreToolUse → evidence-gate.sh
  covering Write/Edit/MultiEdit/NotebookEdit/Bash. One slipped comma in this
  file silently disables the whole enforcement layer. (audit B5-1)
- New `tests/test-sync-local.sh` (+10): sync fidelity against a sandboxed copy
  of the plugin tree — byte-identical commands/agents/hooks/skills, executable
  bits preserved, settings.json untouched, parity warning fires exactly when a
  hook is unregistered, drift is detectable and a re-sync clears it. The sync
  had a silent-omission precedent (evidence-gate.sh, pre-v0.2.2) and no test.
  (audit B5-2)
- CI portability fixes from the first macOS run (5 red assertions, all
  test-side): `mk_sandbox_repo` now canonicalizes the sandbox path (macOS
  $TMPDIR lives under /var → /private/var, so installer-canonicalized paths
  never matched raw mktemp strings); the autoloop progress stub marks backlog
  items with awk instead of GNU sed's `0,/re/` first-match address (BSD sed
  lacks it — the stub never committed and the happy path flaked into the
  breaker); macOS CI installs coreutils so the stop-gate timeout tests run
  instead of SKIPping.
- `commands/polish.md`: documented the dedup-key tradeoff (audit B5-3/P4) —
  `file:line|summary` keeps line drift as accepted verifier-cost noise;
  line-less keys were rejected because they can silently drop one of two
  same-summary findings in a file.
- Suite 143 → 183 assertions: `test-unattended-autoloop` +10 (fake-timeout
  wiring, expire→breaker, backlog-deleted stop, MAX_MINUTES=0),
  `test-install-timer` +3 (pinned claude Environment line, unresolvable-claude
  refusal ×2), `test-unattended-polish` +2 (MAX_MINUTES=0),
  `test-stop-gate` +1 (ceiling disarm hint), `test-evidence-gate` +2 (deny
  message resolves the runner via CLAUDE_PLUGIN_ROOT / placeholder without it).
  install-timer tests now inject a stub claude (`LOOP_ENG_CLAUDE_BIN`) so they
  stay hermetic on claude-less CI.

## 0.4.1 — 2026-07-11

Audit-driven fix batch (source: `docs/audit-report-v0.4.0-2026-07-11.md`). All
are bugfixes / hardening restoring intended behavior; no breaking changes.

### Fixed
- `install-timer.sh`: resolved the unattended runner from the target repo
  (`$REPO/skills/loop-eng/scripts/unattended-<mode>.sh`), so scheduling only
  worked when the target repo WAS the plugin repo — a marketplace-installed
  plugin has its runners in the plugin cache, not in the user's project, so
  `install-timer` failed with "runner not found" against any real target. It now
  resolves the runner from its OWN directory (`dirname "$0"`); the `<repo>` arg
  is purely the project to schedule against. (audit H1)
- `install-timer.sh`: a repo (or plugin) path containing whitespace produced a
  systemd unit that passed `systemctl enable` but failed at first trigger
  (`ExecStart` is whitespace-delimited and injected unquoted; the error only
  reached the journal). It now refuses such a path at install time with a named
  reason, instead of writing a unit that silently never runs. (audit M1)
- `install-timer.sh`: the unit's `StandardOutput/Error` append to
  `$REPO/.loop/cron.log`, which systemd opens before `ExecStart` — but the
  runner's own `mkdir -p .loop` runs inside `ExecStart`, too late for the first
  run's log. Install now pre-creates `$REPO/.loop`. (audit M2)
- `evidence-gate.sh`: the Write/Edit lock on `.loop/criteria.tsv` (and its
  `.sha256`) required the file to already exist (`[ -f "$FILE" ]`), so while a
  legacy `verify.sh` loop was armed a model could CREATE a fresh trivial
  `criteria.tsv` and hijack the stop-gate (which prefers `criteria.tsv` over
  `verify.sh`). The lock now denies the create as well as the overwrite while
  armed. The Bash path already covered this; only the tool path had the gap.
  (audit M4)
- `evidence-gate.sh`: `NotebookEdit` carries its target in `notebook_path`, not
  `file_path`, so the gate read an empty path and let NotebookEdit writes to the
  ledger through unchecked. The parser (jq and python3 branches) now falls back
  to `notebook_path`. (audit L2)

### Tests
- Suite 135 → 143 assertions: `test-install-timer` +3 (plugin-resolved runner,
  `.loop` pre-creation, whitespace refusal), `test-evidence-gate` +5 (armed
  create-deny for `criteria.tsv` abs+rel, not-armed create-allow, NotebookEdit
  deny + allow).

## 0.4.0 — 2026-07-11

### Added
- `install-timer.sh` / `uninstall-timer.sh`: a symmetric pair to schedule the
  unattended polish/autoloop runners as a `systemd --user` timer, instead of
  hand-dropping unit files (which get forgotten, or left "installed but never
  enabled" so they silently never run). `install-timer.sh` writes the
  `.service` + `.timer`, resolves absolute paths, validates `--time`/repo/args,
  and `enable --now`s the timer — a failed enable exits non-zero rather than
  leaving an un-scheduled orphan. `uninstall-timer.sh` disables and removes in
  reverse order and is a benign no-op when nothing is installed. Report-only /
  no-build by default; `--allow-write` opts into the mode's write env. Honors
  `XDG_CONFIG_HOME`; `LOOP_ENG_TIMER_NO_SYSTEMCTL=1` for headless/CI. The timer
  is intentionally not `Persistent` — enabling a persistent timer after the
  day's `OnCalendar` had passed would fire an immediate catch-up run (a surprise
  mid-day execution just from installing); missed nightly runs are skipped, not
  back-filled. 21 new assertions (`tests/test-install-timer.sh`), suite
  110 → 131.

### Fixed
- `run-contract.sh`: a CRLF-authored `criteria.tsv` left the line-ending CR on
  the last (command) column, so `bash -c "true\r"` ran a command whose name
  ended in CR — "command not found" (exit 127). Every passing check reported a
  false RED and the loop could never reach ALL GREEN. Strip the trailing CR
  before execution (the JSON-escaping path already handled CR; the exec path
  did not). Direction was fail-safe (false-RED, never false-green).
- `install-timer.sh`: the "repo-dir does not exist" error printed a blank path
  because the `cd`-based canonicalization overwrote the variable before the
  error fired; it now reports the original argument the user passed.
- Regression coverage for both: suite 131 → 135 (`test-run-contract` +2 CRLF,
  `test-install-timer` +2 nonexistent-repo path).

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
