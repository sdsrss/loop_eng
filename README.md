# loop-eng — Loop Engineering for Claude Code

[![tests](https://github.com/sdsrss/loop_eng/actions/workflows/test.yml/badge.svg)](https://github.com/sdsrss/loop_eng/actions/workflows/test.yml)

> The best model is worth less than the best loop. You stop prompting the agent;
> you design the system that prompts it.

**loop-eng** brings Loop Engineering to Claude Code as an installable plugin:
two self-driving loops built on maker/checker separation, machine-verifiable
contracts, disk-persisted state, hard stop rules — and a Stop hook that
mechanically refuses to let a session quit while its contract is unsatisfied.

## Install

```
/plugin marketplace add sdsrss/loop_eng
/plugin install loop-eng
```

After a marketplace install the commands may resolve namespace-prefixed —
`/loop-eng:autoloop` and `/loop-eng:polish` — if the bare `/autoloop` /
`/polish` form does not resolve.

### Requirements

POSIX shell and git are the only hard requirements. Everything else is probed
at run time and degrades on a documented path rather than failing — but two of
those paths quietly weaken a guard, so they are listed here rather than left in
the scripts' comments.

| Tool | Used by | Absent → |
|---|---|---|
| `jq` **or** `python3` | `evidence-gate.sh` | the gate goes **inert** — it cannot parse the hook event, so it allows every write and says so on stderr (`no jq or python3 available`). See the note below. |
| `sha256sum` / `shasum` / `openssl` | `arm-contract.sh`, `run-contract.sh` | the contract arms **without a hash-lock**, so post-arm drift no longer fails closed. `arm-contract.sh` warns at arm time. |
| `timeout` / `gtimeout` | `stop-gate.sh`, `arm-contract.sh` | the contract runs **unbounded** on each stop attempt; the near-timeout fail-closed guard is inactive and the gate says so. Keep `criteria.tsv` fast. |
| `curl` | `update-notify.sh` | no update-available notices. Silent by design. |
| `systemctl --user` | `install-timer.sh` | scheduling is unavailable; use cron, or `LOOP_ENG_TIMER_NO_SYSTEMCTL=1` to write the unit files only. |
| bash ≥ 4.4 | `unattended-*.sh` only | the unattended drivers refuse to run. The hooks and their scripts run on stock macOS bash 3.2 (CI-tested). |

An inert evidence-gate does **not** forfeit the completion invariant. The gate
is defense-in-depth on the write path; the stop-gate is the load-bearing one,
and it needs no JSON parser. Verified on a parser-less box: a hand-forged
`{"all_green": true}` in `.loop/results.json` is overwritten by
`run-contract.sh` on the next stop attempt (`generated_by` flips back,
`all_green` returns to `false`) and the stop is still blocked. What you lose
without a parser is the early, explanatory denial — not the guarantee.

## The two loops

### `/autoloop <task>` — drive a bounded task to completion

```
contract (binary acceptance criteria, verify commands)
   └─> builder implements ──> checker verifies ──┐
          ^                                      │
          └── full failure report, verbatim <────┘
   until ALL GREEN, max 5 rounds, six stop rules
```

- **Builder** and **checker** are separate subagents. The checker has no
  Write/Edit tools — separation is enforced by tool whitelists, not trust.
- Every claim of "done" is a checker report, never the builder's opinion.
- Six stop rules bound the loop: ALL GREEN · rounds exhausted · same failure
  twice in a row · regression · no progress for 2 rounds · capability boundary.
  Any non-green stop escalates with what was tried and why more rounds won't help.
- State lives in `.loop/state.md` and per-round git commits — the loop survives
  context compaction and session restarts.
- The contract's checks live in `.loop/criteria.tsv` (written at contract
  time; the evidence-gate hook denies rewrites while the loop is armed).
  Columns are **TAB-separated** — `id<TAB>description<TAB>command`. A line that
  uses spaces instead parses as one field and cannot run, so arming warns and
  the contract fails closed rather than going green over the criteria that
  happened to parse. Every stop attempt machine-writes
  `.loop/results.json` + `.loop/evidence/<id>.log` — completion is a
  machine-written fact, not a model claim.

### `/polish [scope] [report-only]` — iteratively raise code quality

```
numeric baseline (tests / lint / types)
   └─> 4 independent review lenses (correctness, simplification,
       test-coverage, consistency) — separate contexts, no cross-talk
   └─> adversarial verification: a skeptic subagent tries to REFUTE
       every finding; only confirmed findings enter the fix queue
   └─> severity-ordered fixes (bugs get a failing test FIRST, then the fix)
   └─> full regression, repeat — converges on a dry round
```

- Behavior-preserving by definition: anything that would change a public
  contract (including deleting exported symbols) is deferred to you, not applied.
- Every improvement claim cites baseline vs. final numbers. No adjectives.
- `report-only` mode finds and verifies without changing anything — the
  required mode for scheduled runs until finding quality is proven.

## How loop-eng relates to /goal and ralph-wiggum

Claude Code now ships loop primitives natively: `/goal` (v2.1.139+) keeps a
session working until a Haiku evaluator judges a condition met, and the
first-party `ralph-wiggum` plugin re-feeds a prompt until the model emits a
completion promise. loop-eng sits above that baseline:

| | native `/goal` | first-party ralph-wiggum | loop-eng |
|---|---|---|---|
| completion decided by | small model reading the transcript (runs no commands) | the working model emits a promise string | the harness re-runs the contract's commands (`run-contract.sh`) |
| criteria | one condition | one prompt | multi-criterion contract, per-criterion evidence log |
| builder/verifier separation | none | none | enforced by tool whitelists |
| iteration bound | until condition or manual clear | unlimited by default | 5 rounds + 6 stop rules, bounded by default |
| completion evidence | evaluator's yes/no | model's self-report | machine-written `.loop/results.json` + raw logs, model writes denied by a PreToolUse gate |
| state | session-scoped | session-scoped | `.loop/` on disk + git; survives restarts |
| unattended | `-p` supported | — | nightly report-only polish + cross-session autoloop driver with circuit breaker and budgets |

Use `/goal` for single-condition supervision of interactive work; use
loop-eng when done must be a machine-verified, multi-criterion fact.

## Stop-gate: enforcement, not promises

While `.loop/active` exists, the plugin's Stop hook re-runs the contract's
checks on every stop attempt — `.loop/criteria.tsv` (via `run-contract.sh`),
falling back to legacy `.loop/verify.sh` when no `criteria.tsv` is present —
and blocks premature exit (exit 2 with the failure output fed back to the
model). A hard ceiling of 3 blocks
guarantees the gate can never deadlock a session, and the gate lifts itself
the moment the contract passes.

A companion PreToolUse hook (`hooks/evidence-gate.sh`) denies model writes
to `.loop/results.json`, `.loop/evidence/`, and the armed `criteria.tsv` (plus
its `criteria.sha256` hash-lock) while the loop is armed (`.loop/active`
present) — via the Write/Edit tools this path is mechanically closed, so
"passes: true" can only be produced by running the command, never typed.
Escape hatch for humans: `LOOP_ENG_DISABLE_EVIDENCE_GATE=1`.

The armed contract is additionally pinned by a **hash-lock**: `arm-contract.sh`
records `sha256(criteria.tsv)`, and `run-contract.sh` fails CLOSED if the live
file no longer matches — catching every write path, including Bash verbs the
gate's regex can't see. What this guarantees is that weakening an armed contract
can never pass *silently*; a fully adversarial model with arbitrary Bash that
rewrites both `criteria.tsv` and its hash-lock in lockstep is out of scope, left
to the red lines in the prompts and human review of the diff.

A *missing* hash-lock used to be the quiet corner of that guarantee: with no
`criteria.sha256` beside it, `run-contract.sh` simply skipped the integrity
check, and a lockless run looked exactly like a locked one. It no longer does.
When the loop is armed, the lock is absent, and a SHA-256 tool is available,
the run warns on stderr and stamps `"contract_lock": "absent"` into
`results.json`.

It reports the **state, not a cause**. Several routes lead there and the runner
cannot tell them apart: `arm-contract.sh` omits the lock on a machine that
cannot hash and when there is no `criteria.tsv` at arm time, the orchestrator's
documented last-resort arm is a bare `touch .loop/active` that never writes one,
and a lock removed after arming looks identical. What they share is the only
thing worth saying — the tamper check did not run, so a `criteria.tsv` weakened
after arming would pass unnoticed.

That is a warning, not a refusal: every one of those routes is legitimate, and
failing closed would strand a live loop whose only exit is deleting
`.loop/active`. The field is in the ledger rather than only on stderr because a
green contract lets the stop-gate exit 0, which discards hook output — so
`"contract_lock"` is what survives to the human reading the record.

Platform note: Claude Code force-allows a stop after 8 consecutive
Stop-hook blocks; loop-eng's ceiling (3) stays safely under it.

Bash compatibility: the hooks (`stop-gate.sh`, `evidence-gate.sh`) and their
scripts (`arm-contract.sh`, `run-contract.sh`) run on stock macOS bash 3.2 —
this is tested in CI, not asserted: a dedicated `test-bash32` job runs the
hooks suites through macOS's `/bin/bash` (3.2) on every push. The unattended
runners are the exception — they need bash ≥ 4.4 (empty-array expansion under
`set -u`) and say so in their headers.

Scope notes:

- **One loop per repo at a time.** `.loop/` is shared, unversioned state: a
  second session arming the same repo overwrites the hash-lock, so the first
  session's contract then fails closed as tampered (safe, but confusing) and
  the two loops fight over `results.json`.
- **The stop-gate guards `/autoloop` only.** `/polish` has no mechanism-layer
  completion gate — its dry-round convergence rests on the orchestration
  prompt and the behavior-preserving red lines, not on a hook.
- **`LOOP_ENG_LOOP_DIR` is a test-only knob** (used by the plugin's own test
  suite). Only `arm-contract.sh`/`run-contract.sh` honor it; the stop-gate and
  evidence-gate are fixed to `.loop/`, so pointing production loops at a
  custom dir silently disarms both hooks.
- **Backing up the ledger:** use `cat .loop/results.json > backup.json` — the
  evidence-gate's Bash pattern cannot tell read-from from write-to direction,
  so `cp`/`mv` touching a protected path is denied even outward.
- **The gate matches the command string, not the write target.** It denies a
  command in which a write verb (`>`/`>>`, `tee`, `mv`, `cp`, `sed -i`,
  `truncate`, `rm`) appears ahead of a protected path in the same segment —
  whether or not that path is what gets written. So `git commit -m "rm
  .loop/results.json on wrap-up"`, or a test command aimed at an unrelated
  mktemp sandbox, is denied although nothing protected is touched. Naming a
  protected path *without* such a verb is not enough to trip it:
  `grep passes .loop/results.json` and `git commit -m "document
  .loop/results.json"` both pass. This is a conservative false positive
  inherent to the best-effort design; reword the command so the verb and the
  literal filename don't co-occur, or have a human use the escape hatch.
- **Register the hooks in one place only.** If a project lists the loop-eng
  hooks in its own `.claude/settings.json` AND the plugin is installed globally,
  every event fires both — a **double-fire**: the stop-gate's block counter then
  climbs by 2 per stop, hitting the ceiling in ~1–2 blocks instead of 3. Pick
  one registration site, not both.
- **The `backlog` criterion is a trust boundary, not a mechanism.** The
  all-boxes-ticked completion check reads `.loop/backlog.md`, which the
  orchestrator can write; so "tick a box only after a checker reports ALL GREEN"
  is a red line the orchestrator honors, not something the hooks enforce — the
  same residual class as the documented "adversarial disarm is out of scope."
- **Resuming an interrupted loop: reconcile before continuing.** After a context
  switch or crash, reconcile `git log` against the backlog ticks FIRST — a box
  may be ticked while its commit is missing, or a commit may have landed with its
  box still unticked. Disk state is the source of truth, but the two must agree
  before the loop moves on.

If your Claude Code version does not auto-load plugin hooks, register manually
in your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "bash \"<plugin-root>/hooks/stop-gate.sh\"" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash",
        "hooks": [ { "type": "command",
          "command": "bash \"<plugin-root>/hooks/evidence-gate.sh\"" } ] }
    ]
  }
}
```

That is the enforcement layer only. The plugin's third hook — the `SessionStart`
update notifier — is left out on purpose: it is fail-open and has nothing to do
with completion enforcement. Timeouts are left out too; a command hook without
one gets the platform default, which is already above the stop-gate's own
contract budget (`LOOP_ENG_GATE_TIMEOUT`, 100s). `tests/test-hooks-json.sh`
holds this snippet's matcher and script names equal to `hooks/hooks.json`, so
the two registration sites cannot drift apart unnoticed.

## Unattended runs

```
skills/loop-eng/scripts/unattended-polish.sh <repo> [scope] [--auto-fix]
```

- Default is **report-only**. Run nightly report-only for a week; grant
  `--auto-fix` (which additionally requires `LOOP_ENG_ALLOW_AUTOFIX=1`)
  only after the findings prove trustworthy.
- Refuses dirty trees, and targets that are not a git work tree at all
  (unattended edits must stay attributable and revertable); logs every run to
  `.loop/unattended.log`. Malformed arguments — a flag in the scope slot, an
  unknown flag — are a usage error (exit 64), never a silent report-only run.
- Scheduling: prefer the systemd timer pair below (tracked, one-command
  removable). Where systemd isn't available, cron works too:
  `0 3 * * * /path/unattended-polish.sh /path/to/repo src/`

Cross-session building (fresh context per backlog item — compaction is not
a recovery strategy):

```
skills/loop-eng/scripts/unattended-autoloop.sh <repo> [max-sessions]
```

- Requires `LOOP_ENG_ALLOW_AUTOBUILD=1`; refuses dirty trees and non-git targets.
- One fresh `claude -p` session per `.loop/backlog.md` item; each session
  starts from `.loop/state.md` + `git log` handoff.
- Circuit breaker: 2 consecutive sessions with no new commits → stop.
  Session cap (default 8), wall-clock budget (`LOOP_ENG_MAX_MINUTES`,
  default 240), one usage-limit wait then exit 75.

### Scheduling with systemd (tracked, one-command removable)

Instead of hand-dropping unit files into `~/.config/systemd/user/` (easy to
forget, easy to leave "installed but never enabled"), use the install/uninstall
pair — it writes the `.service` + `.timer`, enables the timer, and reverses
exactly:

```
skills/loop-eng/scripts/install-timer.sh   <polish|autoloop> <repo> [arg] [--time HH:MM] [--allow-write]
skills/loop-eng/scripts/uninstall-timer.sh <polish|autoloop>
```

- `<repo>` is the project to schedule against — any git repo, not just this
  plugin's own checkout; the installer locates the runner from its own location,
  so an installed-from-marketplace plugin schedules external projects fine. The
  repo path must be whitespace-free (systemd `ExecStart` is unquoted; a spaced
  path is refused at install time rather than silently failing at first run).
- `arg` = scope (polish, default `src/`) or max-sessions (autoloop, default 8);
  `--time` sets the daily `OnCalendar` (default `03:00`). A polish scope must
  exist in the repo (a path or a glob that matches) — otherwise the unit would
  enable cleanly and review nothing every night, so it is refused at install
  time, like the whitespace and `%` cases above.
- **Safe by default**: without `--allow-write` the timer runs polish report-only
  and autoloop refuses to build — a scheduled run cannot modify the repo.
  `--allow-write` injects the mode's write-enable env (`LOOP_ENG_ALLOW_AUTOFIX`
  / `LOOP_ENG_ALLOW_AUTOBUILD`).
- A failed `systemctl enable` exits non-zero (no silent "installed but not
  scheduled"); `uninstall-timer.sh` is a benign no-op when nothing is installed.
- Units log to `<repo>/.loop/cron.log`. `LOOP_ENG_TIMER_NO_SYSTEMCTL=1` writes
  files without calling systemctl (headless / CI).
- The timer is **not** `Persistent`: a run missed because the machine was off at
  the scheduled time is skipped, not caught up. (This is deliberate — a
  persistent timer enabled after the day's time has passed would fire an
  immediate catch-up run, a surprise mid-day execution just from installing.)

## Environment variables

| Variable | Layer | Default | Effect |
|---|---|---|---|
| `LOOP_ENG_ALLOW_AUTOFIX` | `unattended-polish.sh` | unset (`0`) | Required together with the `--auto-fix` flag before `unattended-polish.sh` will write fixes; without it the run stays report-only. |
| `LOOP_ENG_ALLOW_AUTOBUILD` | `unattended-autoloop.sh` | unset (`0`) | Required before `unattended-autoloop.sh` will drive a builder; without it the driver refuses to run. |
| `LOOP_ENG_ARM_REDCHECK` | `arm-contract.sh` | `1` (enabled) | Set to `0` to skip the arm-time advisory red-check entirely — zero criterion commands executed. |
| `LOOP_ENG_ARM_REDCHECK_TIMEOUT` | `arm-contract.sh` | `10` (seconds) | Per-criterion timeout budget for the arm-time red-check; non-numeric or `0` falls back to `10`. |
| `LOOP_ENG_CLAUDE_BIN` | `unattended-polish.sh`, `unattended-autoloop.sh`, `install-timer.sh` | `claude` | Path/name of the `claude` CLI binary the unattended runners and the systemd timer installer invoke. |
| `LOOP_ENG_DISABLE_EVIDENCE_GATE` | `hooks/evidence-gate.sh` | unset (`0`) | Human escape hatch: set to `1` to disable the PreToolUse evidence-gate hook, letting a legitimate mid-loop contract edit through. |
| `LOOP_ENG_GATE_TIMEOUT` | `hooks/stop-gate.sh` | `100` (seconds) | Internal budget for re-running the contract on each stop attempt, kept below the hook's own timeout in `hooks.json` (120s) so the gate fails closed by design instead of being killed by the platform. |
| `LOOP_ENG_LIMIT_WAIT_MIN` | `unattended-autoloop.sh` | `60` (minutes) | Wait once and retry after a session log indicates a provider usage/rate limit; a second hit stops the driver (exit 75). |
| `LOOP_ENG_LOOP_DIR` | `arm-contract.sh`, `run-contract.sh` | `.loop` | **TEST-ONLY.** The stop-gate and evidence-gate hooks are fixed to `.loop/`; pointing a production loop at a custom dir with this var silently removes it from both hooks' protection. |
| `LOOP_ENG_MAX_MINUTES` | `unattended-polish.sh`, `unattended-autoloop.sh` | `120` (polish) / `240` (autoloop) | Wall-clock budget enforced via `timeout` for the unattended run; `0` is a config error (would disable the timeout) and falls back to the script's default. |
| `LOOP_ENG_TIMER_NO_SYSTEMCTL` | `install-timer.sh`, `uninstall-timer.sh` | unset (`0`) | Set to `1` to write the systemd unit files without calling `systemctl` — used by the test suite, also useful on a box with no user D-Bus. |

## Safety model

| Principle | Enforcement |
|---|---|
| Verifier ≠ implementer | checker/reviewer/verifier agents have no Write/Edit tools (they keep Bash — they must run the checks — so this is a whitelist, not a sandbox) |
| Done = machine signal | contracts allow only binary criteria with verify commands |
| Done = machine-written fact | results.json/evidence written only by run-contract.sh; PreToolUse gate denies model writes |
| Never weaken a check to pass it | red line in every agent + orchestrator |
| Loops can't run away | round caps, block ceiling, same-failure and no-progress brakes |
| Red actions stay human | money / production / schema / public API are never looped |
| Output is a proposal | every run ends by showing the diff for human review |
| Test/build output is untrusted text | checker reports are forwarded verbatim by design (fidelity over filtering); prompt-injection riding in tool output is a residual covered by the red lines and the human review of the diff |

- **Unattended write mode is real code execution without approval.**
  `unattended-autoloop.sh` and `unattended-polish.sh` both invoke
  `claude -p ... --permission-mode bypassPermissions` — once you opt in, a
  scheduled run can modify and **commit** to your repo with no human in the
  loop. It is **off by default** (report-only / no-build) and requires an
  explicit opt-in: `LOOP_ENG_ALLOW_AUTOFIX=1` (with `--auto-fix`) for
  `unattended-polish.sh`, `LOOP_ENG_ALLOW_AUTOBUILD=1` for
  `unattended-autoloop.sh`, or `--allow-write` on `install-timer.sh` (which
  injects the matching env var into the scheduled unit). Guards on top of
  that opt-in — dirty-tree refusal, a commit-keyed circuit breaker, wall-clock
  and session caps — bound the blast radius; they don't ask permission.
- **`.loop/` is local state, not auto-removed.** The loop's bookkeeping
  directory (`.loop/` — contract, criteria, `results.json`, `evidence/`,
  `state.md`) is gitignored but lives in your working tree. Neither the
  plugin uninstall nor `uninstall-timer.sh` deletes it — by design, since it
  may hold an in-progress loop's state. If you want it gone, remove it by
  hand: `rm -rf .loop/`.
- **One file outlives an uninstall.** The update notifier's 24h throttle stamp
  lives at `${XDG_CACHE_HOME:-~/.cache}/loop-eng/update-check.json` — outside
  `~/.claude/`, deliberately, so it survives a version bump instead of being
  orphaned in the version-pinned plugin cache. `/plugin uninstall` does not
  know about it. It is one line of JSON (a timestamp and a version string, no
  identifiers); `rm -rf ~/.cache/loop-eng/` if you want a clean slate. Nothing
  else the plugin writes lives outside your project's `.loop/`.

## What to loop (and what not to)

**Good fits**: reproducible bugfixes, refactors under test coverage, adding
tests, consistency sweeps, library migrations with a compile/test gate.

**Bad fits**: architecture decisions, greenfield code with no tests to verify
against, zero-coverage legacy (build the safety net first), anything touching
production or external side effects.

## Repository layout

```
.claude-plugin/   plugin.json + marketplace.json
commands/         /autoloop, /polish orchestrators
agents/           loop-builder, loop-checker, loop-reviewer, loop-verifier
hooks/            stop-gate.sh + evidence-gate.sh + hooks.json
skills/loop-eng/  skill entry, contract/state templates, unattended runner
```

## Design provenance

Distilled from the 2026 Loop Engineering literature (Boris Cherny, Addy Osmani,
Anthropic's planner/generator/evaluator harness work) and hardened against the
documented failure modes: self-grading leniency, verifier theater, infinite
fix loops, test-weakening, comprehension debt, reviewer over-reporting on
sound code, and cross-session amnesia. Key positions taken: safety valves
live in the mechanism layer (tool whitelists, hooks, counters), not in prompt
text; and a loop's output is always a proposal, never an accomplished fact.

## License

MIT
