---
description: Drive a bounded task to completion via an autonomous builder/checker loop. Use when the user wants hands-off execution to a machine-verifiable finish line — "keep going until tests pass", "don't stop until it's done", unattended/挂机/无人值守/自动跑完/修到全绿 — or hands over a bugfix/refactor with binary pass-fail checks. Rounds repeat until ALL GREEN or a stop rule fires (max 5); a Stop hook blocks premature quitting. Not an interval timer.
argument-hint: <task>
allowed-tools: Read, Write, Grep, Glob, Bash, Task
---

Execute this task as a closed loop: $ARGUMENTS

You are the orchestrator. You NEVER edit source files yourself — the only files
you may write are under `.loop/`. All code changes go through the loop-builder
subagent; all verification goes through the loop-checker subagent.

## Step 0 — Align

Preconditions first:

- `git status` must be clean (untracked `.loop/` bookkeeping is fine). If
  dirty, STOP and tell the user — the final diff must be attributable to the
  loop alone, and a dirty tree makes the wrap-up diff conflate the user's
  uncommitted work with the loop's changes.
- Record the baseline ref: run `git rev-parse HEAD` and write it into
  `.loop/state.md` as `Baseline: <hash>`. The final report's diff (Step 3 and
  Wrap-up) is `git diff <baseline>..HEAD` — without a recorded baseline there
  is nothing exact to diff against after multiple builder commits.

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

### Roadmap input (a document instead of a task)

When $ARGUMENTS points at a roadmap / checklist document (a file path or a
pasted prioritized list) rather than a single task, run a TRIAGE step before
the contract. Treat the document's item order as priority order — do not
reorder. For each item, in order:

- **loopable** — a binary verify command is derivable, the scope is inside
  this repo, no red action (prod / schema / payments / user-global state),
  no human interaction required → one backlog line carrying its verify
  command: `- [ ] <item> | verify: <command>`.
- **too big for one round** → split into loopable sub-items (each with its
  own verify command), inserted at the parent's position.
- **not loopable** → do NOT put it in the backlog. Record it in
  `.loop/state.md` under `## Deferred (not loopable)` with a one-line reason:
  needs-human / interactive / no-machine-verify / out-of-repo-scope.

Trivial micro-items MAY share a round. When several items are each a single
file, under ~5 lines, and carry a purely static verify (grep / file-exists),
group them into ONE backlog round instead of burning a full
builder+checker+suite cycle per one-liner. Grouping shares only the round
boundary: still make ONE commit per item inside that round, so per-item
traceability in the wrap-up diff is preserved — only the checker+suite pass is
amortized across the batch.

State the triage result (backlog + deferred, with reasons) in one message,
then proceed — do not wait for confirmation; the contract layer is the
safety net (an unverifiable criterion warns at arm time and can never go
green by claim). If more than 5 items are loopable, the 5-round cap still
binds: finish what fits, leave the rest unchecked in the backlog and say so
— the user re-invokes /autoloop to continue (checkboxes persist), or
schedules unattended-autoloop.sh to consume the remainder across fresh
sessions.

When looping a multi-item backlog, the checker for each round judges ONLY the
current round's item — its target criterion plus the suite. The other global
criteria that belong to not-yet-built items are expected-red and are NOT that
round's failure; otherwise round 1 would trip a stop rule (regression / no
progress) on items 2..N that have not been built yet. Each item goes green in
its own round, in document order, and stays green thereafter — so a later round
still watches for regressions in items already ticked, but never counts the
still-pending ones against the current round's item.

The wrap-up report for a roadmap run MUST end with a three-part ledger:
**Done** (checked items, each with its proof line) / **Deferred** (with
reasons) / **Remaining backlog** (unchecked items, if the cap cut the run).

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
  silently, whatever write path is used. (In this plugin's own repo, dogfooding
  via the `.claude/` copy, `${CLAUDE_PLUGIN_ROOT}` is undefined — use
  `bash .claude/skills/loop-eng/scripts/arm-contract.sh` there instead; do not
  skip the hash-lock. Only if arm-contract.sh is unavailable through BOTH paths,
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
3. If the checker's report starts with `ALL GREEN`: stop. First REFRESH the
   machine ledger so it reflects the fixed tree — run
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/loop-eng/scripts/run-contract.sh"`
   (same dogfood fallback as the arm step: in this plugin's own repo use
   `bash .claude/skills/loop-eng/scripts/run-contract.sh`)
   (the builder and checker run the raw verify commands, NOT run-contract, so
   `.loop/results.json` is still the pre-fix run and would show a stale
   `all_green: false` until it is re-run). Then show me the full diff
   (`git diff <baseline>..HEAD`, the baseline ref recorded in Step 0) and each
   check's proof line.
   Cite the just-refreshed `.loop/results.json` (`all_green: true`) as the
   machine proof, and the per-criterion evidence files under `.loop/evidence/`.
   (The Stop hook also re-runs the contract on your stop attempt; refreshing it
   here makes the citation truthful at the moment you write it.)
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

## Cost management (per-round model tiering)

Each round dispatches a fresh builder and a fresh checker, and the dominant
token cost on a SMALL task is this fixed per-round overhead (full contract +
brief + agent prompt), not the diff or the test output. Two levers, in order of
safety:

- Batch trivial micro-items into one round (the triage rule above) — amortizes a
  whole builder+checker+suite cycle across several one-liners.
- For a genuinely trivial round (single file, < ~10 lines, a purely static
  verify — the same class that qualifies for batching), you MAY dispatch
  loop-builder at a cheaper model tier via the Task tool's model parameter to
  cut the fixed overhead. Hard invariant: the checker's tier must be **>= the
  builder's tier** — never let a weaker model certify a stronger model's work,
  that inverts the maker/checker rigor the loop exists to provide. When in doubt
  do NOT downgrade: inherit the session model (the default). Never downgrade the
  builder on a round that touches hooks/, run-contract, arm-contract, or any
  mechanism-layer script — correctness there outweighs the token saving.

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

After the loop ends, how you disarm depends on the outcome:
- **ALL GREEN** — do NOT manually disarm at all. End the turn and
  let the stop-gate self-clear: when the contract passes on the real stop
  attempt the stop-gate removes `.loop/active`, `.loop/gate-count`, and
  `.loop/criteria.sha256` itself. Manually deleting them here short-circuits
  that final machine verification — you would tear the gate down before it has
  confirmed, on the genuine stop, that the tree still passes.
- **ESCALATION stop** (a legitimate end where the contract will never go green)
  — the stop-gate will never self-clear on a red contract, so disarm it
  yourself IN TWO SEPARATE Bash commands, in this order:
  1. `rm -f .loop/active .loop/gate-count`
  2. `rm -f .loop/criteria.sha256`
  The order matters: while `.loop/active` exists, the evidence-gate denies ANY
  Bash command touching `criteria.sha256` — including this legitimate wrap-up —
  so a single `rm` of all three files is denied. Removing `active` first
  disarms that lock and the second command passes. Never leave the gate armed
  behind you.
- Append one line to `.loop/lessons.md` in the fixed format:
  `- <YYYY-MM-DD> | <task one-liner> | rounds <n> | <ALL GREEN|stop-rule-N> | <one reusable lesson, or "-">`
  If a memory system is available (e.g.
  mem_save or an equivalent CLI), also save the lesson there — lessons that
  only live in one repo don't compound.
