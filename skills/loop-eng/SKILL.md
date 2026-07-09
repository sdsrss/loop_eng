---
name: loop-eng
description: Closed-loop task execution and quality polishing for Claude Code. Use when the user wants a task driven to completion autonomously (/autoloop builder-checker cycle), wants the codebase quality-polished iteratively (/polish review-verify-fix cycle), or asks about the loop-eng workflow.
---

# loop-eng — closed-loop task execution & quality polishing

Two entry points:

- `/autoloop <task>` — drive a bounded task to completion: contract →
  builder/checker rounds → ALL GREEN or escalation. See
  `.claude/commands/autoloop.md` for the full protocol.
- `/polish [scope]` — iterative quality improvement: numeric baseline →
  4 independent review lenses → adversarial verification of every finding →
  fix queue → full regression → repeat until a dry round (no fresh confirmed
  findings). Behavior-preserving by definition; public-contract changes are
  listed for the human, never applied. See `.claude/commands/polish.md`.

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

## Templates

- `templates/contract.md` — acceptance contract skeleton
- `templates/state.md` — per-round state file skeleton
