---
description: Quality-polish loop — baseline, multi-lens review, adversarial verify, fix, converge on a dry round
argument-hint: [scope, e.g. src/ — defaults to the whole project source]
allowed-tools: Read, Write, Grep, Glob, Bash, Task
---

Polish the code quality of: $ARGUMENTS (if empty: the project's main source
directory — state which one you chose).

Report-only mode: if $ARGUMENTS contains `report-only`, run Phases 0–2 (baseline,
review, adversarial verification) but SKIP Phase 3 entirely — no fixes, no file
changes outside `.loop/`. Output the verified findings ledger and stop. This is
the required mode for unattended/scheduled runs during their observation period:
prove finding quality is stable before granting auto-fix.

You are the orchestrator. You NEVER edit source files yourself — the only files
you may write are under `.loop/`. Fixes go through the loop-builder subagent,
review through loop-reviewer, verification through loop-verifier, regression
through loop-checker.

## Phase 0 — Preconditions

- `git status` must be clean (untracked `.loop/` is fine). If dirty, STOP and
  tell the user — polish must be attributable and revertible as one diff.
- Record the baseline ref: `git rev-parse HEAD`.

## Phase 1 — Baseline (numbers, not vibes)

Discover the project's check commands (same procedure as loop-checker) and run
them. Record in `.loop/polish-state.md`:
- test: pass/fail counts
- lint: warning/error counts
- types: error count
- coverage % (only if the project already measures it — do not add tooling)

Every later claim of improvement must cite these numbers as its baseline.
No adjectives.

## Phase 2 — Review round (macro rounds, max 3)

1. Dispatch loop-reviewer subagents IN PARALLEL, one per lens:
   correctness, simplification, test-coverage, consistency.
   Each gets: the scope paths, its lens, nothing else — independent contexts
   are the point; do not share one reviewer's findings with another.
2. Collect findings. Deduplicate against `.loop/polish-seen.md` (every finding
   ever reported this run, keyed `file:line|summary`). Append fresh ones to the
   seen file. Dedup against SEEN, not against confirmed — otherwise refuted
   findings resurface every round and the loop never converges.
3. For each fresh finding, dispatch loop-verifier (one finding per dispatch,
   parallel). Only `VERDICT: CONFIRMED` findings enter the fix queue.
4. **Dry-round check**: if zero fresh findings were confirmed this round →
   the loop has converged → go to Wrap-up.

## Phase 3 — Fix round

1. Order the fix queue: high severity first; within a severity, correctness >
   test-coverage > simplification > consistency.
2. For each confirmed finding, dispatch loop-builder with the finding verbatim
   (file:line, defect, failure scenario). Batch only trivially independent
   low-severity items. Builder rules apply (root cause, no drive-by changes,
   commit per fix).
   - correctness fixes: if the bug is not covered by an existing test, the
     builder MUST first add a failing test reproducing it, then fix
     (red → green — proof the bug was real and is gone).
   - simplification fixes: behavior-preserving only; existing tests must stay
     green with zero test modifications.
3. Dispatch loop-checker for a full regression after the queue is done.
   - ALL GREEN → update `.loop/polish-state.md` (round summary: found /
     confirmed / refuted / fixed) and return to Phase 2 for the next round.
   - FAILED → autoloop's stop rules apply: identify which fix broke it,
     have the builder fix or `git revert` that commit; a fix that cannot be
     made green in 2 attempts is reverted and its finding recorded as
     `deferred (fix regressed)`.

## Stop rules

- Dry round (0 fresh confirmed findings) → converged, normal end.
- 3 macro rounds exhausted → stop, report what remains in the queue.
- Regression that cannot be reverted cleanly → stop immediately, report.
- Any finding whose fix would change public API/contract, schema, or behavior
  users depend on → do NOT fix; list it for the human. Polish is
  behavior-preserving by definition.
- Deleting or renaming any EXPORTED symbol counts as a public-contract change,
  even when Grep finds zero internal references — external consumers are
  invisible to Grep. Defer it to the human list. Exception: the human already
  authorized cleanup, or the scope is a non-published application entry point.

## Degraded mode

If subagent dispatch is unavailable (some headless contexts), run the lenses
yourself sequentially and label the final report `degraded mode:
single-context review` — never silently pretend independent review happened.
Verification by execution (running tests/repros) remains mandatory, and so does
the commit-per-fix discipline — degraded mode degrades independence, not
traceability.

## Wrap-up

Report:
1. Baseline vs final numbers table (tests, lint, types, coverage if measured).
2. Findings ledger: reported / refuted-by-verifier / confirmed / fixed /
   deferred, each with file:line.
3. The full diff (`git diff <baseline-ref>..HEAD`) — polish output is a
   proposal for human review, not an accomplished fact.
4. Append one entry to `.loop/lessons.md`.

## Red lines

- Never weaken or delete a check/test to keep something green.
- Never claim "cleaner/simpler/better" without a number or a concrete before/after.
- Never fix anything the verifier did not confirm.
- Never touch public contracts.
