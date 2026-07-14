---
name: loop-eng
description: Closed-loop task execution and quality polishing for Claude Code. Use when the user wants a bounded task driven to completion hands-off — "keep iterating until tests pass", "don't stop until done", 自动循环/挂机/无人值守/跑到全绿 — via /autoloop (builder/checker rounds); wants code quality raised iteratively with every finding adversarially verified before fixing — 打磨/清理代码 — via /polish (review-verify-fix rounds); or asks how the loop-eng workflow works. Unlike prompt-only goal trackers, the Stop hook executes the contract's real verify commands and completion evidence is machine-written.
---

# loop-eng — closed-loop task execution & quality polishing

Two entry points:

- `/autoloop <task>` — drive a bounded task to completion: contract →
  builder/checker rounds → ALL GREEN or escalation. Also accepts a
  prioritized roadmap/checklist document: it triages items in document order
  (loopable → backlog with verify commands; too-big → split; not-loopable →
  deferred with reasons), loops the backlog, and ends with a
  Done / Deferred / Remaining ledger. See `commands/autoloop.md` (in this
  plugin) for the full protocol.
- `/polish [scope]` — iterative quality improvement: numeric baseline →
  4 independent review lenses → adversarial verification of every finding →
  fix queue → full regression → repeat until a dry round (no fresh confirmed
  findings). Behavior-preserving by definition; public-contract changes are
  listed for the human, never applied. See `commands/polish.md` (in this plugin).

## Which tasks fit a loop

GOOD fits (bounded goal + machine-verifiable done):
- Bug fixes with a reproducible failing check
- Small-to-medium refactors under existing test coverage
- Adding tests for existing code
- Style/consistency sweeps, library migrations with a compile/test gate

BAD fits (do NOT loop these — handle interactively):
- Architecture decisions, greenfield projects with no tests to verify against
- Legacy code with zero test coverage (build the safety net first)
- Anything touching production, databases/migrations, payments, external
  side effects — red actions always go through a human

## Core invariants (all loops)

1. Contract before code: `.loop/contract.md` for humans plus
   `.loop/criteria.tsv` (binary verify commands, fixed while the loop is
   armed) for the machine.
2. Maker/checker separation is enforced by tool whitelists, not trust:
   loop-builder can write, loop-checker cannot.
3. State lives on disk (`.loop/state.md`), not in the context window.
4. Six stop rules bound every loop at 5 rounds max.
5. Never weaken a check to make it pass.
6. Loop output is a proposal: always end with the diff for human review.
7. Completion evidence is machine-written: `run-contract.sh` produces
   `.loop/results.json` + `.loop/evidence/`; the evidence-gate hook denies
   model writes to them.

Asymmetry worth knowing: the stop-gate (criteria.tsv / `.loop/active`)
mechanically enforces /autoloop's completion contract. /polish has no
mechanism-layer completion gate — its dry-round convergence rests on the
orchestration prompt and the behavior-preserving red lines. One loop per
repo at a time: `.loop/` is shared state.

## Templates

- `templates/contract.md` — acceptance contract skeleton
- `templates/state.md` — per-round state file skeleton
