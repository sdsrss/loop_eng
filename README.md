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

## Stop-gate: enforcement, not promises

While `.loop/active` exists, the plugin's Stop hook re-runs the contract's
`.loop/verify.sh` on every stop attempt and blocks premature exit (exit 2 with
the failure output fed back to the model). A hard ceiling of 3 blocks
guarantees the gate can never deadlock a session, and the gate lifts itself
the moment the contract passes.

If your Claude Code version does not auto-load plugin hooks, register manually
in your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "bash \"<plugin-root>/hooks/stop-gate.sh\"" } ] }
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
- Cron example: `0 3 * * * /path/unattended-polish.sh /path/to/repo src/`

## Safety model

| Principle | Enforcement |
|---|---|
| Verifier ≠ implementer | checker/reviewer/verifier agents have no write tools |
| Done = machine signal | contracts allow only binary criteria with verify commands |
| Never weaken a check to pass it | red line in every agent + orchestrator |
| Loops can't run away | round caps, block ceiling, same-failure and no-progress brakes |
| Red actions stay human | money / production / schema / public API are never looped |
| Output is a proposal | every run ends by showing the diff for human review |

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
hooks/            stop-gate.sh + hooks.json
skills/loop-eng/  skill entry, contract/state templates, unattended runner
```

## Design provenance

Distilled from the 2026 Loop Engineering literature (Boris Cherny, Addy Osmani,
Anthropic's planner/generator/evaluator harness work) and hardened against the
documented failure modes: self-grading leniency, verifier theater, infinite fix
loops, test-weakening, comprehension debt. Key positions taken: safety valves
live in the mechanism layer (tool whitelists, hooks, counters), not in prompt
text; and a loop's output is always a proposal, never an accomplished fact.

## License

MIT
