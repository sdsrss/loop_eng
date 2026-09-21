---
description: Iteratively raise code quality until a review round comes back clean. Use when the user asks to polish/clean up a module or codebase — 打磨/清理/提升代码质量 — or wants review findings actually fixed, not just listed. Unlike a one-shot code review, every finding is adversarially verified, then fixed and regression-tested, looping until a dry round (no fresh finding entered the fix queue). Behavior-preserving — public-contract changes are reported, never applied.
argument-hint: [scope, e.g. src/ — defaults to the whole project source]
allowed-tools: Read, Write, Grep, Glob, Bash, Task, Agent
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
- Check for a leftover `.loop/active`. `/polish` arms no contract of its own, so
  it never creates one — but the Stop hook is command-agnostic: while
  `.loop/active` exists it re-runs that contract on your stop attempts and
  blocks while it is unsatisfied (`hooks/stop-gate.sh` has other allow paths —
  a contract-less arm, a dedup replay, the 3-block ceiling — but none of them
  spare you the blocks). So an `active` left behind by a killed or ceilinged
  `/autoloop` costs you rounds over a contract that has nothing to do with this
  run. If it is there,
  record it and disarm the same way `/autoloop` Step 0 does: `rm -f .loop/active`
  first, then `rm -f .loop/gate-count .loop/criteria.sha256` as a SECOND Bash
  call (one command naming both `active` and `criteria.sha256` is itself denied).
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
2. Collect findings. Deduplicate against TWO ledgers:
   - `.loop/polish-seen.md` — every finding ever reported this run, keyed
     `file:line|summary`. Append fresh ones, each recorded WITH ITS LENS: the
     reviewer prints the lens once as a report header, not per finding, so it is
     yours to attach here — the verifier echoes it back but nothing else in the
     pipeline reconstructs it, and Phase 3 cannot dispatch without it. Dedup
     against SEEN, not against confirmed — otherwise refuted findings resurface
     every round and the loop never converges.
     (Known noise, accepted by design: after a fix round shifts line numbers, an
     already-seen finding can re-enter as "fresh" at its new line and cost one
     extra verifier pass — the verifier absorbs it. Keying without the line was
     rejected: two genuinely distinct findings in one file can share a summary,
     and line-less dedup would silently drop one. Noise is acceptable; losing a
     real finding is not.)
   - `.loop/polish-deferred.md` — findings handed to the human under the
     public-contract stop rule, keyed `file|summary` **without the line**.
     A deferred finding is never fixed, so nothing ever moves it out of the
     code; with a line in the key it re-entered as "fresh" after every fix
     round that shifted lines above it, was re-verified into the same CONFIRMED
     verdict, and was deferred again. That costs a verifier pass per round AND
     keeps the loop alive on a finding it has already decided not to act on —
     the one class for which line-less dedup cannot lose a real finding, since
     the outcome is fixed in advance. Record each deferral here the moment it
     is made, and skip anything matching on the next round.
3. For each fresh finding, dispatch loop-verifier (one finding per dispatch,
   parallel). Only `VERDICT: CONFIRMED` findings with impact `correctness` or
   `requirement` enter the fix queue. Confirmed `optional` findings go to the
   report's "Optional (not queued)" list — they are the human's call, not the
   loop's. A confirmed finding that the public-contract stop rule below forbids
   fixing goes to `.loop/polish-deferred.md` and the human list, not the queue.
4. **Dry-round check**: if no fresh finding entered the FIX QUEUE this round →
   the loop has converged → go to Wrap-up. Queued, not merely confirmed: a
   confirmed finding that is `optional`, or deferred as a public-contract
   change, is one the loop will never act on, so counting it as round activity
   keeps the loop running with nothing left to do.

## Phase 3 — Fix round

1. Order the fix queue: high severity first; within a severity, correctness >
   test-coverage > simplification > consistency.
2. For each finding in the fix queue, dispatch loop-builder with the finding
   verbatim (file:line, defect, failure scenario) plus BOTH labels, named as
   such: its **lens** (`correctness` / `test-coverage` / `simplification` /
   `consistency`) and its **impact class** (`correctness` / `requirement` /
   `optional`). They are different vocabularies that share the word
   `correctness`, the reviewer's report line carries only the impact class, and
   the builder's discipline keys off the LENS — so passing one token labelled
   "category" is how a test-coverage fix arrives under a rule that forbids
   touching tests. Batch only trivially independent
   low-severity items. Builder rules apply (root cause, no drive-by changes,
   commit per fix).
   Cost: a low-severity single-file fix MAY dispatch the builder at a cheaper
   model tier. Hard invariant (same as /autoloop): reviewer, verifier, and
   checker are judgment tiers — NEVER downgrade them below the builder's tier;
   when in doubt, inherit the session model.
   - correctness fixes: if the bug is not covered by an existing test, the
     builder MUST first add a failing test reproducing it, then fix
     (red → green — proof the bug was real and is gone).
   - test-coverage fixes: the fix IS a test change, so the zero-modification
     rule below does not apply to it. Add the missing assertion, then prove it
     is load-bearing — break the code it claims to cover, see the new assertion
     go red, restore, see it green. An assertion that passes both ways pins
     nothing.
   - simplification / consistency fixes: behavior-preserving only; existing
     tests must stay green with zero test modifications.
3. Dispatch loop-checker for a full regression after the queue is done.
   - ALL GREEN → update `.loop/polish-state.md` (round summary: found /
     confirmed / refuted / fixed) and return to Phase 2 for the next round.
   - FAILED → regression protocol: identify which fix broke it,
     have the builder fix or `git revert` that commit; a fix that cannot be
     made green in 2 attempts is reverted and its finding recorded as
     `deferred (fix regressed)`.

## Stop rules

- Dry round (no fresh queued findings) → converged, normal end.
- 3 macro rounds exhausted → stop, report what remains in the queue.
- Regression that cannot be reverted cleanly → stop immediately, report.
- Any finding whose fix would change public API/contract, schema, or behavior
  users depend on → do NOT fix; record it in `.loop/polish-deferred.md`
  (keyed `file|summary`, no line) and list it for the human. Polish is
  behavior-preserving by definition.
- Deleting or renaming any EXPORTED symbol counts as a public-contract change,
  even when Grep finds zero internal references — external consumers are
  invisible to Grep. Defer it to the human list. Exception: the human already
  authorized cleanup, or the scope is a non-published application entry point.

## Degraded mode

If subagent dispatch is unavailable (some headless contexts), run the lenses
yourself sequentially and label the final report `degraded mode:
single-context review` — never silently pretend independent review happened.
Verification by execution (running tests/repros) remains mandatory — degraded
mode degrades independence, not rigour. What it cannot degrade is the rule
above: you NEVER edit source files yourself, the only files you may write are
under `.loop/`, and a dispatch failure does not suspend that. With no
loop-builder to dispatch there is nobody left who may apply a fix, so
**degraded mode is report-only**: run the lenses, verify by execution, write
the ledger, hand the fix queue to the user, and say plainly that nothing was
applied. The commit-per-fix discipline still governs those fixes — it just
binds whoever picks the queue up, which in this mode is not you.

## Wrap-up

Report:
1. Baseline vs final numbers table (tests, lint, types, coverage if measured).
2. Findings ledger: reported / refuted-by-verifier / confirmed / fixed /
   deferred / optional-not-queued, each with file:line and impact class.
3. The full diff (`git diff <baseline-ref>..HEAD`) — polish output is a
   proposal for human review, not an accomplished fact.
4. Append one entry to `.loop/lessons.md`.

## Red lines

- Never weaken or delete a check/test to keep something green.
- Never claim "cleaner/simpler/better" without a number or a concrete before/after.
- Never fix anything the verifier did not confirm.
- Never touch public contracts.
