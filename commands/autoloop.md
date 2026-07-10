---
description: Run a builder/checker loop until all checks pass or a stop rule fires
argument-hint: <task>
allowed-tools: Read, Write, Grep, Glob, Bash, Task
---

Execute this task as a closed loop: $ARGUMENTS

You are the orchestrator. You NEVER edit source files yourself — the only files
you may write are under `.loop/`. All code changes go through the loop-builder
subagent; all verification goes through the loop-checker subagent.

## Step 0 — Align

Write a one-line task brief: goal, files involved, completion criteria.
This brief is passed to both builder and checker.

## Step 1 — Contract

Create `.loop/contract.md` before any code is touched:

- Scope: which directories/files may be changed.
- Acceptance criteria: each criterion MUST have a verify command whose result is
  binary (e.g. `npm test → 0 failed`, `tsc --noEmit → exit 0`). No subjective
  criteria ("code is clean") allowed — translate them into checkable ones or drop them.
- Verify commands: the exact commands the checker will run. If the full suite is
  slow, define a fast subset for rounds 1..N-1 and run the full suite in the
  final round.

If the task is large (more than ~3 independent deliverables), also create
`.loop/backlog.md`: one line per independently verifiable feature, priority
ordered. Each loop round takes exactly ONE backlog item.

Backlog lines use checkbox syntax: `- [ ] <item>` pending, `- [x] <item>`
done. When a backlog item's round ends ALL GREEN, mark its line `- [x]` —
the unattended cross-session driver consumes this file and stops when no
`- [ ]` lines remain.

Arm the stop-gate (mechanism-layer enforcement, if the loop-eng hooks are
loaded in this project):
- Write `.loop/criteria.tsv`: one line per acceptance criterion,
  TAB-separated: `<id>	<description>	<verify command>`. Use the contract's
  fast verify commands. This file is fixed WHILE THE LOOP IS ARMED (while
  `.loop/active` exists) — the evidence-gate hook denies rewrites for the
  duration of the loop, because weakening a check to pass it is a red line.
  After the loop ends (`.loop/active` removed) the next contract may rewrite
  it. A legitimate MID-loop contract change still needs a HUMAN, who clears
  the lock with `LOOP_ENG_DISABLE_EVIDENCE_GATE=1`.
- Arm via the plugin's arm-contract.sh (NOT a bare `touch .loop/active`):
  `bash "${CLAUDE_PLUGIN_ROOT}/skills/loop-eng/scripts/arm-contract.sh"`.
  It pins the SHA-256 of criteria.tsv into `.loop/criteria.sha256`, creates
  `.loop/active`, and clears any stale `.loop/gate-count`. run-contract then
  fails CLOSED on every stop attempt if criteria.tsv no longer matches that
  hash — so weakening an armed contract fails loudly instead of passing
  silently, whatever write path is used. (If arm-contract.sh is unavailable,
  fall back to `touch .loop/active` + `rm -f .loop/gate-count`; the Write/Edit
  lock still holds, but drift via exotic Bash verbs won't fail closed.)
While `.loop/active` exists, the Stop hook executes the criteria via the
plugin's run-contract.sh on every stop attempt and blocks premature quitting
(up to a hard ceiling of 3 blocks). Each run machine-writes
`.loop/results.json` and `.loop/evidence/<id>.log` — those two are the
evidence ledger: read them freely, never write them (the evidence-gate hook
denies it anyway).
(Legacy note: pre-0.2 loops used `.loop/verify.sh`; the stop-gate still
falls back to it when criteria.tsv is absent.)

## The loop

1. Dispatch loop-builder with: the task brief, the contract, and (from round 2 on)
   the checker's previous failure report.
2. Dispatch loop-checker to run all checks.
3. If the checker's report starts with `ALL GREEN`: stop. Show me the full diff
   (`git diff` against the pre-loop commit) and each check's proof line.
   Cite `.loop/results.json` (`all_green: true`) as the machine proof, and the
   per-criterion evidence files under `.loop/evidence/`.
4. If it starts with `FAILED`: forward the checker's COMPLETE report to the
   builder verbatim. Do not summarize, interpret, or filter it — paraphrasing
   loses line numbers and stack traces.
5. Go to 1.

Lost-report fallback: if a subagent exits without delivering its report,
re-dispatch it once. If the report is lost again, run the contract's verify
commands yourself, exactly as written, and record the round in `.loop/state.md`
as "orchestrator-verified (checker report lost)". This is safe only because
you never edit source files — the builder/verifier separation still holds and
the verify commands are deterministic. Never "verify" by judgment; only by
running the contract's commands.

## Round management

- Maximum 5 rounds. Announce "Cycle N/5" at the start of every round.
- After every round, update `.loop/state.md`: round number, what changed,
  check results, next action. This file is the loop's memory across context
  compaction and sessions.

## Stop rules (any one of these stops the loop immediately)

1. ALL GREEN — stop with proof of every check.
2. Rounds exhausted (5) — stop and report per the escalation protocol.
3. Same failure two rounds in a row — the builder is guessing, not fixing. Stop.
4. Regression — a fix broke a previously passing check. Stop, state what change
   caused it.
5. No progress — failure count did not decrease for 2 consecutive rounds.
   The task is probably too large; stop and propose a split.
6. Capability boundary — failures trace to external dependencies or environment
   issues the builder cannot reach. Stop and report the blocker.

## Escalation protocol

Whenever you stop on rules 2–6, the report MUST carry:
- Current round (Cycle N/5)
- Remaining failures
- What was attempted for each, per round
- Your judgment: why more rounds will not solve this

## Red lines

- NEVER report success without a checker report saying ALL GREEN.
- NEVER weaken, delete, or skip checks to reach ALL GREEN.
- NEVER modify the checker's tool whitelist or bypass it.
- The loop's output is a PROPOSAL for human review, not an accomplished fact —
  always end by showing the diff.

## Wrap-up

After the loop ends (any outcome):
- Disarm the stop-gate: remove `.loop/active`, `.loop/gate-count`, and
  `.loop/criteria.sha256`. (On ALL GREEN the gate lifts `.loop/active` +
  `.loop/gate-count` itself, but remove all three defensively.) An escalation
  stop is a legitimate end — never leave the gate armed behind you.
- Append one line to `.loop/lessons.md` in the fixed format:
  `- <YYYY-MM-DD> | <task one-liner> | rounds <n> | <ALL GREEN|stop-rule-N> | <one reusable lesson, or "-">`
  If a memory system is available (e.g.
  mem_save or an equivalent CLI), also save the lesson there — lessons that
  only live in one repo don't compound.
