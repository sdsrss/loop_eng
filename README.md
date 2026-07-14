# loop-eng — Loop Engineering for Claude Code

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
  Every stop attempt machine-writes
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

Platform note: Claude Code force-allows a stop after 8 consecutive
Stop-hook blocks; loop-eng's ceiling (3) stays safely under it.

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

## Unattended runs

```
skills/loop-eng/scripts/unattended-polish.sh <repo> [scope] [--auto-fix]
```

- Default is **report-only**. Run nightly report-only for a week; grant
  `--auto-fix` (which additionally requires `LOOP_ENG_ALLOW_AUTOFIX=1`)
  only after the findings prove trustworthy.
- Refuses dirty trees; logs every run to `.loop/unattended.log`.
- Scheduling: prefer the systemd timer pair below (tracked, one-command
  removable). Where systemd isn't available, cron works too:
  `0 3 * * * /path/unattended-polish.sh /path/to/repo src/`

Cross-session building (fresh context per backlog item — compaction is not
a recovery strategy):

```
skills/loop-eng/scripts/unattended-autoloop.sh <repo> [max-sessions]
```

- Requires `LOOP_ENG_ALLOW_AUTOBUILD=1`; refuses dirty trees.
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
  `--time` sets the daily `OnCalendar` (default `03:00`).
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

## Safety model

| Principle | Enforcement |
|---|---|
| Verifier ≠ implementer | checker/reviewer/verifier agents have no write tools |
| Done = machine signal | contracts allow only binary criteria with verify commands |
| Done = machine-written fact | results.json/evidence written only by run-contract.sh; PreToolUse gate denies model writes |
| Never weaken a check to pass it | red line in every agent + orchestrator |
| Loops can't run away | round caps, block ceiling, same-failure and no-progress brakes |
| Red actions stay human | money / production / schema / public API are never looped |
| Output is a proposal | every run ends by showing the diff for human review |
| Test/build output is untrusted text | checker reports are forwarded verbatim by design (fidelity over filtering); prompt-injection riding in tool output is a residual covered by the red lines and the human review of the diff |

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
