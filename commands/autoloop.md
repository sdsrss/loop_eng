---
description: Drive a bounded task to completion via an autonomous builder/checker loop. Use when the user wants hands-off execution to a machine-verifiable finish line — "keep going until tests pass", "don't stop until it's done", unattended/挂机/无人值守/自动跑完/修到全绿 — or hands over a bugfix/refactor with binary pass-fail checks. Rounds repeat until ALL GREEN or a stop rule fires (max 5); a Stop hook blocks premature quitting. Not an interval timer.
argument-hint: <task>
allowed-tools: Read, Write, Grep, Glob, Bash, Task, Agent
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
- Check for a stop-gate left armed by a previous session: if `.loop/active`
  exists BEFORE you arm anything, a killed or ceilinged loop left it. The
  evidence-gate will deny your Step 1 write to `.loop/criteria.tsv` while it is
  there, so the round cannot start. Record the leftover in `.loop/state.md`,
  then disarm in this order — `rm -f .loop/active`, then
  `rm -f .loop/gate-count .loop/criteria.sha256` as a SECOND Bash call (one
  command naming both `active` and `criteria.sha256` is itself denied).
- `.loop/` must not be tracked by git. Run `git ls-files .loop` — if it prints
  anything, STOP and tell the user to untrack it
  (`git rm -r --cached .loop && echo '.loop/' >> .gitignore`). `results.json`
  is rewritten on every stop, so a tracked `.loop/` leaves the tree dirty
  forever: the wrap-up diff is polluted and every unattended run afterwards
  refuses with "dirty tree". (An UNtracked `.loop/` needs nothing from you —
  `arm-contract.sh` adds it to `.git/info/exclude` in Step 2.)
- Record the baseline ref: run `git rev-parse HEAD` and write it into
  `.loop/state.md` as `Baseline: <hash>`. The final report's diff (Step 3 and
  Wrap-up) is `git diff <baseline>..HEAD` — without a recorded baseline there
  is nothing exact to diff against after multiple builder commits.

Write a one-line task brief: goal, files involved, completion criteria.
This brief is passed to both builder and checker.

Dogfood fallback (later steps point here): dogfooding this plugin's own repo
via the `.claude/` copy, `${CLAUDE_PLUGIN_ROOT}` is undefined — substitute
`.claude/` in every script reference below
(e.g. `bash .claude/skills/loop-eng/scripts/arm-contract.sh`); never skip the
hash-lock. Last resort, arm-contract.sh unavailable via BOTH paths:
`touch .loop/active` + `rm -f .loop/gate-count` — Write/Edit lock still holds,
but exotic-Bash drift won't fail closed.

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

Backlog lines use checkbox syntax: `- [ ] <item> | verify: <command>`
pending, `- [x] <item> | verify: <command>` done — each line carries its
verify command so per-item machine-verifiable criteria survive into the
backlog, same format as roadmap triage below. The unattended cross-session
driver consumes this file and stops when no `- [ ]` lines remain.

**You do not tick these boxes.** `run-contract.sh` runs each pending line's
verify command on every stop attempt and ticks the line when it exits 0 — the
box is a machine-written fact, exactly like `"passes": true` in the ledger, and
the tick lands in `.loop/results.json` under `"backlog"`. While the loop is
armed the evidence-gate DENIES writes to a backlog carrying `| verify:` lines,
so an attempt to tick one yourself is refused. If a box will not tick, the
verify command is failing — fix the code, or the command, before the loop is
armed. (A backlog with no `| verify:` commands at all is the older
model-ticked shape: nothing runs and nothing is locked. Prefer verify
commands — a box you can type is a claim, not a result.)

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
The same-failure and no-progress counters (stop rules 3 and 5) reset at each
item boundary: they compare rounds only WITHIN the current item. Item N+1's
first round reporting its own expected-red target is a fresh start, not "no
progress" relative to item N's ALL-GREEN round.

The wrap-up report for a roadmap run MUST end with a three-part ledger:
**Done** (checked items, each with its proof line) / **Deferred** (with
reasons) / **Remaining backlog** (unchecked items, if the cap cut the run).

Arm the stop-gate (mechanism-layer enforcement, if the loop-eng hooks are
loaded in this project):
- Write `.loop/criteria.tsv`: one line per acceptance criterion,
  TAB-separated: `<id>	<description>	<verify command>`. Use the contract's
  fast verify commands — write this file FROM that table, so the two say the
  same thing. They are two statements of one contract and only this one runs:
  the stop-gate executes it, and `all_green` is computed from it alone. If they
  ever disagree, THIS FILE is the contract and `.loop/contract.md` is stale
  prose — fix the prose, and say so in the wrap-up.
  This file is fixed WHILE THE LOOP IS ARMED (while
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
  silently, whatever write path is used. (Dogfood fallback: Step 0.)
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
2. Dispatch loop-checker to run the checks — scoped to the round. On a
   multi-item backlog, an intermediate round's checker runs the current item's
   checks plus the already-ticked items' criteria (the contract's fast
   subset); the full sweep (the run-everything command, e.g. the whole test
   runner) runs ONCE, in the final round. Full-sweeping every intermediate
   round re-buys assurance the fast subset already gives and multiplies
   checker wall-clock by the round count (2026-07-14 dogfood: 5 rounds of
   full sweeps caught nothing the fast subset would have missed).
3. If the checker's report starts with `ALL GREEN`, that verdict is about THIS
   round's item, not about the loop. On a multi-item backlog the checker judges
   only the current item (its criteria plus the suite) and lists the rest as
   EXPECTED-RED, so round 1 legitimately reports `ALL GREEN` while items 2..N
   have not been built — taking it as "the loop is done" would stop after one
   item and report a diff for a backlog barely started. So:
   - FIRST reconcile the report against the machine ledger, BEFORE ticking
     anything. Run
     `bash "${CLAUDE_PLUGIN_ROOT}/skills/loop-eng/scripts/run-contract.sh"`
     (dogfood fallback: Step 0) and read the refreshed `.loop/results.json`.
     The checker's report is a claim; the ledger is a run. **When they disagree
     the ledger wins** — it was produced by executing the armed contract, and it
     is the file the stop-gate will consult on your stop attempt anyway, so a
     disagreement discovered here is one you would otherwise meet as a block
     with no round left to fix it in.
     - Any criterion belonging to THIS round's item that is `"passes": false`
       → the round is FAILED, whatever the report said. Forward those criteria
       to the builder verbatim (id, cmd, exit, and the `evidence` log path) and
       go to 1. Do NOT tick the box.
     - Criteria belonging to items not yet built are EXPECTED-RED and are not
       this round's failure — the same scoping rule the checker follows.
     - A `"malformed_lines"` field or an `"error"` field means the contract was
       only partly parsed or could not run at all. That is never a green round:
       fix `.loop/criteria.tsv` — which needs a human, since the evidence-gate
       locks it while armed (`LOOP_ENG_DISABLE_EVIDENCE_GATE=1`) — and say so.
   - the current item's backlog line is ticked by the run-contract call you just
     made, from its `| verify:` command's exit status — do not tick it yourself
     (the evidence-gate denies it). Read the refreshed `.loop/backlog.md`: if
     the line is still `- [ ]`, its verify command did not pass, so the item is
     NOT done whatever the checker said — treat the round as FAILED and go to 1
     with that command's failure. A backlog line carrying no `| verify:`
     command is the older model-ticked shape; tick that one yourself, and say in
     the wrap-up that it was ticked on a report rather than a run;
   - if any `- [ ]` line remains and the round budget is not exhausted, go to 1
     with the next item;
   - only when no `- [ ]` line remains (or there was no backlog at all) is the
     loop finished — then do the wrap-up below.

   Wrap-up, once the loop is finished: the reconcile step above has just
   refreshed the machine ledger, so it already reflects the fixed tree — that
   refresh is why it is there. (The builder and checker run the raw verify
   commands, NOT run-contract, so without it `.loop/results.json` would still
   be the pre-fix run and show a stale `all_green: false`.) Then show me the full diff
   (`git diff <baseline>..HEAD`, the baseline ref recorded in Step 0) and each
   check's proof line.
   Cite the just-refreshed `.loop/results.json` (`all_green: true`) as the
   machine proof, and the per-criterion evidence files under `.loop/evidence/`.
   If that ledger carries `"contract_lock": "absent"`, say so in the same
   breath as the green: it means no hash-lock was in force, so the contract
   this run verified is not provably the contract that was armed. Reporting
   `all_green` while silently dropping that qualifier overstates the proof —
   and a field nothing is told to read is not a safeguard.
   (The Stop hook also re-runs the contract on your stop attempt; refreshing it
   here makes the citation truthful at the moment you write it.)
4. If it starts with `FAILED`: forward the checker's COMPLETE report to the
   builder verbatim. Do not summarize, interpret, or filter it — paraphrasing
   loses line numbers and stack traces.
5. Go to 1.

Dispatch both subagents synchronously — await each one's result within the same
turn, and give the dispatch no teammate name. Do NOT rely on a
`run_in_background: false` parameter: the current Agent tool has no such input,
so "set it to false" is not an instruction you can carry out. What you control
is the shape of the dispatch — one subagent per dispatch, awaited before you do
anything else, no parallel fan-out.

This matters because an async dispatch ends the orchestrator's turn while the
subagent is still working, and every such turn-end hits the armed stop-gate on a
still-red contract. With two dispatches per round against a 3-block ceiling,
that reaches the ceiling inside round 2 — and a headless run then exits with the
gate still armed, which is the stale-`.loop/active` state Step 0 exists to clean
up. The builder's report can also arrive as a duplicate late message after the
loop has closed, and the block text will prompt you to "keep fixing" while a
builder is still mid-edit, inviting a second builder into the same files.

Observed rather than assumed: on Claude Code CLI 2.1.278 the dispatch is
synchronous and a full round completed to `all_green: true` (0.14.0 smoke). If
your harness dispatches subagents in the background, expect the spurious blocks
above; that is a harness property this prompt cannot override.

Lost-report fallback: if a subagent exits without delivering its report,
re-dispatch it once. If the report is lost again, run the contract's verify
commands yourself, exactly as written, and record the round in `.loop/state.md`
as "orchestrator-verified (checker report lost)". This is safe only because
you never edit source files — the builder/verifier separation still holds and
the verify commands are deterministic. Never "verify" by judgment; only by
running the contract's commands.

## Round management

- **5 rounds is the TOTAL budget for the invocation, not a per-item allowance.**
  One backlog item may take several rounds — that is the normal case, since the
  builder fixes one root cause per round — and a five-item backlog may well not
  finish. Announce "Cycle N/5" at the start of every round, counting every round
  of every item in one sequence.
- Each round takes exactly ONE backlog item (micro-items may share a round, see
  the triage rule above), and an item is finished when the checker reports
  `ALL GREEN` for it, not when its first round ends.
- When the budget runs out with items unticked, stop per the escalation
  protocol and say which items are left. The checkboxes persist, so the user
  re-invokes `/autoloop` to continue, or schedules `unattended-autoloop.sh` to
  consume the remainder across fresh sessions.
- Stop rules 3 and 5 reset at each item boundary (see the multi-item section
  above); the round counter does NOT.
- After every round, update `.loop/state.md`: round number, current item, what
  changed, check results, next action. This file is the loop's memory across
  context compaction and sessions.

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

1. ALL GREEN — every `- [ ]` backlog item is ticked (or there was no backlog and
   the single task's criteria all pass). Stop with proof of every check.
2. Rounds exhausted (5) — stop and report per the escalation protocol.
3. Same root cause two rounds in a row — the builder is guessing, not fixing.
   Stop. Judge this by the builder's `Root cause:` line, NOT by the failure.
   The builder fixes ONE root cause per round by design, so a criterion with two
   independent causes behind it is still red after the first is fixed: the
   failure repeats while the work is progressing. A repeated *failure* is
   therefore not evidence of guessing; a repeated *named cause* is. `Root cause:
   not identified` two rounds running counts as a repeat.
4. Regression — a fix broke a previously passing check. Stop, state what change
   caused it.
5. No progress — the number of RED criteria in `.loop/results.json` did not
   decrease for 2 consecutive rounds. The task is probably too large; stop and
   propose a split. Count from the ledger, not from the checker's failure list:
   the checker merges failures per file for readability (`loop-checker.md`), so
   its list length tracks how the defects are distributed across files rather
   than how many there are. Refresh the ledger with `run-contract.sh` before
   comparing if the round did not already.
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
