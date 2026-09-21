# Changelog

## 0.18.0 — 2026-09-21

The backlog half of a loop accepted less than it locked. The evidence-gate has
always frozen a backlog line on a tolerant pattern, while the runner ticked one
strict shape — so a line in the gap was untickable by *anyone*: the model's
write denied, the box unable to move, and an unattended driver re-picking the
same item until its circuit breaker fired. This round makes the runner accept
exactly what the gate locks, moves the counters that had to follow it, and
closes two writes that could publish a partial result over a whole one.

**Minor, not a patch, on purpose.** Nothing here adds a feature. The bump is
owed because a released artifact now *accepts* input it used to refuse — the
mirror image of the call 0.17.0 made for a new refusal — and because an
unattended run's exit code can move as a direct result (see Upgrade). A
scheduler can observe that; a version string is the only advance signal a user
on `^0.17` gets before their next nightly behaves differently. To keep the old
behaviour, pin `0.17.0`.

### Upgrade

- **The runner now ticks backlog shapes it used to walk past.** An optional
  indent, a `-`, `*` or `+` bullet, and any whitespace — or none — between `|`
  and `verify:`. That is exactly the pattern `hooks/evidence-gate.sh` already
  locks, so the set of lines the gate freezes and the set the runner can check
  off are the same set again. If your backlog has indented or `*`-bulleted
  items, boxes that never moved before will now move on their own; the tick
  preserves your indentation and your marker rather than normalizing to
  `- [x]`, because ticking a box is not reformatting someone's markdown.
  Ordered-list markers (`1. [ ]`) stay outside the grammar on every side —
  locked by the gate, never ticked, and deliberately not counted as pending, so
  a driver is never pinned on an item nothing can check off.
- **A scheduled `/autoloop` can now exit 1 where it used to exit 0.**
  `unattended-autoloop.sh` counts pending items and picks the next one in that
  same widened grammar. A run that met one of those shapes previously logged
  `backlog empty — done` and exited 0 over unfinished work; it now keeps
  launching sessions against those items, and if it stops with any still
  pending it exits 1, as it has always done for a backlog it could not drain.
  That is the fix rather than a regression — but if you alert on the driver's
  exit status, expect jobs that were green over an unfinished backlog to start
  failing honestly. The README's documented `backlog` criterion was widened the
  same way and for the same reason: anchored at column 0 with a literal `-`, it
  reported PASS over an unfinished `* [ ]` or indented item.

### Fixed

- **A backlog line could be locked and untickable at the same time.** The gate
  denies model writes to any `.loop/backlog.md` line matching
  `|[[:space:]]*verify:`, while the runner required the literal `| verify: `
  behind a 6-character `- [ ] ` prefix. `|verify:` with no space, a TAB after
  the pipe, two spaces, an indented item, a `*` or `+` bullet: each was frozen
  by the gate and invisible to the runner, so the box could never move and the
  loop could only end at a stop rule or a human disarm. Fixed on the strict
  side, restoring `locked ⊆ tickable` — narrowing the gate instead would have
  satisfied the same arithmetic while producing a box a model can type, which
  is the one thing this plugin exists to prevent.
- **A TAB-indented `#comment` in `criteria.tsv` forced the contract red on
  every stop.** `run-contract.sh` probed for a leading `#` *after* splitting the
  line into TAB columns, while `arm-contract.sh` probes the whole line — so
  `<TAB># disabled<TAB>…` armed clean and then failed closed as "partly parsed"
  on every stop attempt, with `criteria.tsv` already locked and only a human
  disarm able to clear it. `<space><TAB># disabled<TAB>cmd` was worse: the id
  column was a non-empty space, so the commented-out criterion *ran*. The
  comment and blank probes now sit above the split in both scripts. Their
  malformed-line warning was reworded to match: it blamed columns "separated by
  SPACES" on lines whose indent is a TAB, in a file that contains no spaces
  between columns at all, which is what made the original incident hard to read.
- **A ledger that could not be published exited with the contract's verdict
  anyway.** `mv "$TMP" "$RESULTS"` was the one unchecked write in the runner, so
  a hygiene criterion that sweeps temp files (`find . -name "*.tmp.*" -delete`,
  `make clean`) could delete the temp ledger mid-run and leave the *previous*
  contract's `results.json` on disk as the surviving record — a frozen
  `all_green: true` that the orchestrator reconciles against and then reads as
  "no progress" forever. It now fails closed with exit 73 (`EX_CANTCREAT`). The
  stop-gate was never fooled: it branches on its own re-run, not on this file.
- **A backlog rewrite that lost a write truncated the live backlog.** The
  cat-back into `.loop/backlog.md` truncates at redirect setup, so it is safe
  only if every write to the temp copy landed. Two ways it was not: the `-1`
  poison sentinel was clobbered by the first ticked item (a 3-item backlog
  rewritten to 0 bytes, run still exiting 0), and the appends were unchecked, so
  a write failing mid-rewrite published a prefix and reported `all_green: true`
  over it. It takes a `.loop/` write failing mid-run to reach — ENOSPC first —
  and no model action can: the gate denies writes to a backlog carrying verify
  commands. It is worth hardening because `.loop/` is gitignored and the rewrite
  is in place, so the user's items are simply gone.
- **Two enforcement arms were held in place by nothing.** Deleting the
  `systemctl --user enable --now` half of `install-timer.sh`'s install — which
  ships exactly the trap that script exists to kill, "installed but never
  enabled, so they silently never run" — survived the whole suite; the evidence
  was already being recorded and then truncated before anything read it.
  Dropping either redirect on the backlog's verify command survived too: without
  `</dev/null` a stdin-reading command eats the remaining backlog items out of
  the enclosing loop, and without `>/dev/null` a *printing* command (the
  README's own `npx vitest run` example) writes its output into the middle of
  `results.json`, which still exits 0 and still allows the stop — only the JSON
  stops parsing. Each mutation now turns the suite red. Suite: **865 → 942
  assertions**, 13 suites, shellcheck `-S warning` 0 findings.

### Live-install smoke

Passed on Claude Code 2.1.278, against a real marketplace install of this
release from the GitHub source (`sdsrss/loop_eng`) into a throwaway
`CLAUDE_CONFIG_DIR`, with the hooks under
`plugins/cache/loop-eng/loop-eng/0.18.0/` instrumented so every verdict is a
machine fact rather than a model's report:

- **arm** cited the cache copy under test — `armed from
  …/plugins/cache/loop-eng/loop-eng/0.18.0/skills/loop-eng/scripts/arm-contract.sh`,
  not the `plugins/marketplaces/` clone.
- **evidence-gate** denied `echo hello > .loop/evidence/smoke.log` (the Bash
  form — the Write form false-PASSed while smoking 0.17.0). File absent
  afterwards, and the marker recorded `EGDENY
  root=…/plugins/cache/loop-eng/loop-eng/0.18.0`, so `CLAUDE_PLUGIN_ROOT`
  reached the hook process.
- **stop-gate** blocked a RED contract three times and then released at the
  ceiling, twice over: markers `SGBLOCK-contract` ×3 → `CEILING-RELEASE`, ×2
  cycles. Every block took the contract-unsatisfied path — none took the
  missing-runner, dedup-replay or timeout exits, which is what distinguishes a
  healthy block from a broken install. On disk: `generated_by:
  run-contract.sh`, `all_green: false`.
- **`${CLAUDE_PLUGIN_ROOT}` in command bodies** expanded: a full
  `/loop-eng:autoloop` run armed, reached `all_green: true` on two criteria,
  wrote the acceptance artifact, and lifted `.loop/active` itself. The marker
  log was **empty** for that run — the same instrumentation that recorded six
  blocks in the step above recorded none here, which is the control that makes
  the six meaningful.

## 0.17.0 — 2026-09-20

The completion invariant had one input a model could still write, and one branch
order that let the wrong script answer for a contract. Both are closed, and the
three arms that a mutation could delete without turning the suite red are now
pinned.

**Minor, not a patch, on purpose.** Nothing here adds a feature; the reason for
the bump is that a released artifact now *refuses* something it used to accept,
and a version string is the only signal a user on `^0.16` gets before their
next loop behaves differently. It is the same call 0.15.0 made when
`install-timer.sh` began rejecting an install it had accepted. To revert the
new denial without downgrading, set `LOOP_ENG_DISABLE_EVIDENCE_GATE=1` (which
turns the whole PreToolUse gate off — it is the human escape hatch, not a
per-rule switch); to revert the release, pin `0.16.1`.

### Upgrade

- **While a loop is armed, `.loop/verify.sh` is now read-only to the model.**
  Writing, editing or removing it through Write/Edit/MultiEdit/Bash is denied
  the same way `.loop/criteria.tsv` already was, and creating one is denied too.
  Authoring a `verify.sh` *before* arming is unchanged, running it is unchanged,
  and once the loop disarms the file is writable again — so an ordinary legacy
  loop sees no difference. If you have a workflow where the model rewrites
  `verify.sh` mid-loop, it will now get an `evidence-gate DENIED` instead: split
  it (`rm .loop/active` first), or use the documented human escape hatch
  `LOOP_ENG_DISABLE_EVIDENCE_GATE=1`.
- **A broken install now blocks the stop instead of quietly allowing it.** If
  `.loop/criteria.tsv` is present but `run-contract.sh` cannot be found — an
  interrupted `/plugin update`, or a Stop hook registered by a path outside the
  plugin root — the gate now fails closed even when a legacy `verify.sh` sits
  beside it. Previously a green `verify.sh` answered in its place: the stop was
  allowed and `.loop/active` removed, so the loop ended looking finished. If you
  hit the new block, its stderr names the runner path it looked for — reinstall
  with `/plugin update loop-eng`, or re-register the Stop hook by the plugin's
  own path. To end such a loop without verifying it, `rm .loop/active`, as
  before.

### Fixed

- **A model could rewrite its own gate.** In a legacy loop — one armed without a
  `criteria.tsv`, which `arm-contract.sh` still supports — `.loop/verify.sh`
  *is* the contract: the stop-gate executes it and nothing else. It was the one
  gate input missing from the evidence-gate's protected set, and unlike
  `criteria.tsv` it has no hash-lock behind it to catch the drift, so rewriting
  it to `exit 0` produced a passing stop that nothing downstream could
  distinguish from an earned one. That is the exact claim this plugin exists to
  make impossible. Severity is high and reachability is low: the current
  `/autoloop` and `/polish` always arm with a `criteria.tsv`, so the exposed
  shape is a hand-armed or leftover `.loop/`. Twelve assertions now cover it,
  including the one that must NOT flip — `bash .loop/verify.sh` is still
  allowed, because a frozen gate still has to run. The close is not total, and
  the asymmetry is worth knowing: `criteria.tsv` has run-contract's hash
  re-derivation behind the gate, `verify.sh` has nothing behind it, so the Bash
  verbs outside the gate's conservative pattern — `ln`, `install`, an
  interpreter one-liner, a path held in a variable — still reach it. Arming with
  a `criteria.tsv` is the shape that gets the full guarantee.
- **A green legacy script could answer for a red contract, and disarm the loop
  on its way out.** The stop-gate resolved its contract source in the order
  `criteria.tsv` → legacy `verify.sh` → missing-runner-fail-closed, so a tree
  holding *both* files with no runner present took the legacy branch: the
  `criteria.tsv` the loop was actually armed with was never executed, and a
  `verify.sh` exiting 0 both allowed the stop and removed `.loop/active`. The
  documented behaviour — fail closed on "a `criteria.tsv` whose runner it cannot
  find" — did not hold whenever a `verify.sh` sat beside it, and the reachable
  cause is the same interrupted `/plugin update` that removes the runner while
  leaving the rest of `.loop/` alone. The missing-runner arm now precedes the
  legacy one; `verify.sh` still answers for loops that have no `criteria.tsv`.
- **Three enforcement arms were held in place by nothing.** Deleting `MultiEdit|`
  from the evidence-gate's write-tool arm, breaking the `python3` fallback
  parser's command extraction (the whole Bash branch in jq-less environments),
  or gutting the stop-gate's no-`timeout`-binary path (how the contract runs on
  a stock macOS) each left all 834 assertions green. Each mutation now turns the
  suite red. Suite: **834 → 865 assertions**, 13 suites, shellcheck `-S warning`
  0 findings, six bash-3.2-floor suites re-verified under a real 3.2.57.

**Live-install smoke: PASS** (Claude Code 2.1.278, headless, throwaway
`CLAUDE_CONFIG_DIR`, GitHub-source install of this release's own content on
`main` — no source-type disclosure owed). Live cache copies instrumented, so
every verdict below is a marker on disk rather than a model's report:
`EGDENY root=…/plugins/cache/loop-eng/loop-eng/0.17.0` — the gate fired and
`CLAUDE_PLUGIN_ROOT` reached the hook process resolved to the version-pinned
cache copy, not a placeholder; `armed from …/0.17.0/…`; exactly three `SGBLOCK`
markers then `SGCEILING` on a red contract, with the ledger machine-written
(`generated_by: run-contract.sh`, `all_green: false`); `/loop-eng:autoloop`
reached ALL GREEN and lifted its own gate (`all_green: true`, `.loop/active`
gone), which is the `${CLAUDE_PLUGIN_ROOT}`-expands-in-command-markdown half.
This release's own change was smoked too: with the loop armed, a model write to
`.loop/verify.sh` produced one `EGDENY` and no file, while `bash .loop/verify.sh`
produced none — the freeze holds and the thing that must not flip did not.
Post-ship identity diff against a second fresh config dir: one line,
`Only in …/0.17.0: .in_use`.

One new trap, now in `RELEASING.md` §1 step 4: the smoke's Write-tool form can
false-PASS. Asked to Write `.loop/evidence/smoke.log`, the model reported the
harness had blocked the tool for an unrelated reason and never reached the gate
— file absent, `EGDENY` count **0**, which reads exactly like a pass. The Bash
redirect form is the one that reliably reaches the hook.

## 0.16.1 — 2026-09-20

One fix, found by measuring the loops rather than reading them, plus the cost
table that measurement produced.

### Upgrade

- **A scheduled run will now take as long as you told it to.** Until this
  release both drivers were cut off after ten minutes by a CLI ceiling neither
  of them set (see Fixed below), so a nightly job has been finishing far inside
  its budget and reporting success. It will now run up to `LOOP_ENG_MAX_MINUTES`
  — **120 minutes for polish, 240 for autoloop** — and consume tokens for that
  whole time. Nothing to do if those defaults are what you want; lower them, or
  export `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` yourself to keep the old
  behaviour, if they are not. The measured shape of a run is now in the
  README's "What a run costs".

### Fixed

- **An unattended run was bounded by a ceiling neither driver set, twelve to
  twenty-four times shorter than the one it did.** In print mode the CLI waits
  for still-running background tasks, then **terminates them and exits 0** —
  after `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, whose default is 600000 (10
  minutes). Both loops dispatch subagents the harness may run in the
  background, so that default, not `LOOP_ENG_MAX_MINUTES` (120 for polish, 240
  for autoloop), was the real bound on every scheduled run. Nothing downstream
  could notice: the truncated session exits 0 with `is_error: false`, a
  report-only polish is exempt from the post-run check, and the autoloop driver
  reads that exit as a finished round. Found by measurement rather than by
  reading — a headless `/polish hooks/` reported `subagent_stats`
  `killed.system: 1` with 4 of 5 dispatches completed, and still exited 0; the
  same scope with the ceiling lifted completed **18** dispatches (4 reviewers,
  12 verifiers, 2 workers) in 25 minutes. Both drivers now hand the session
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, leaving the `timeout` wrapper as
  the single budget it was written to be; exporting the variable yourself still
  wins. The suites gained the piece that made this invisible — the stub
  recorded argv but not the environment, so a bound the driver never set was
  one no assertion could see.

### Changed

- **The README says what a run costs, from two measured runs rather than an
  estimate.** A plugin whose pitch is "leave it running" owed a number and had
  none. An `/autoloop` round fixing a failing assertion: 3 dispatches, 25,293
  output tokens, 5.7 minutes. A `/polish` macro round over four files: 18
  dispatches, 354,188 output tokens, 24.9 minutes. The four token classes are
  listed apart on purpose — cache reads are 89% of the polish traffic and the
  cheapest class, so one summed figure would overstate the load about 9× — and
  the dollar column is labelled as the list-price computation it is, which is
  not what a subscription pays. The note that makes the table reproducible is
  the one that cost the most to learn: read `modelUsage`, not the top-level
  `usage` block, which covers the main thread's last turn and counts no
  subagent at all.
- **The unattended section says how far to trust itself.** Closing the audit's
  six `--allow-write` blockers moved that path from "not production-grade" to
  usable, and every guard is now documented mechanism by mechanism — but the
  README stated no posture at all, so the only readiness verdict a reader could
  find was the one in the audit report, which is untracked and was written
  against 0.14.0. The new paragraph says what backs the write path (a test
  suite and a live-install smoke) and what does not (a record of long
  unattended write runs), and keeps report-only as the mode to schedule first.
  Deliberately no assertion count: the README cites none anywhere, and a
  hard-coded one goes stale the next time a suite grows.

**Live-install smoke: PASS** (Claude Code 2.1.278, headless, throwaway
`CLAUDE_CONFIG_DIR`, GitHub-source install of this release's own content on
`main` — no source-type disclosure owed). Live cache copies instrumented, so
each verdict is a marker on disk: the evidence-gate's `deny()` fired with
`CLAUDE_PLUGIN_ROOT` resolved to the real
`plugins/cache/loop-eng/loop-eng/0.16.1` path and the file never landed;
`armed from …/0.16.1/…`; exactly three `SGBLOCK` markers then
`CEILING-RELEASE` on a red contract, with the ledger machine-written
`"all_green": false`; and `/loop-eng:autoloop` reached ALL GREEN, left a
two-criteria ledger, and cleared `active`, `gate-count` and `criteria.sha256`
with zero blocks.

## 0.16.0 — 2026-09-20

Closing out the 2026-09-20 production-readiness audit: 0.15.0 took every P0 and
P1, this entry takes the P2 and P3 remainder. Each item keeps the project's own
discipline — the assertion that would have caught it first, then the fix.

### Upgrade

- **A backlog box is now ticked by a command, not by a claim.** `.loop/backlog.md`
  was the last link in the completion chain a model could simply type: the
  all-boxes-ticked check read a file the orchestrator writes, so "tick a box
  only after the checker reports ALL GREEN" was a red line honoured rather than
  a fact produced. A line written `- [ ] <item> | verify: <cmd>` is now ticked
  by `run-contract.sh` when that command exits 0, on every stop attempt, with
  the outcome recorded in `.loop/results.json` under `"backlog"`; while the loop
  is armed the evidence-gate denies model writes to a backlog carrying any such
  line. Only **pending** lines are re-verified, so the cost is proportional to
  work remaining rather than to work done. A red backlog item does **not** turn
  a green contract red — the backlog is progress, and draining it is the
  orchestrator's job across rounds, not one stop attempt's.

  **Opting in is what locks the file**, so nothing changes for a backlog
  without `| verify:` commands: nothing runs, nothing is denied, and the
  orchestrator ticks boxes as before. That shape remains a trust boundary and
  is now labelled as one. README also spells out the `backlog` criterion it had
  referred to without ever defining: `! grep -q '^- \[ \]' .loop/backlog.md`.
- **The evidence-gate now denies `rm -rf .loop` while a loop is armed.** That
  one command takes the stop-gate's marker, the hash-lock and the evidence
  ledger together, so however innocently it is typed it is a disarm — and it is
  the command this README hands humans for cleanup, which is what made it the
  likeliest accidental one. The refusal names the two-step form: `rm
  .loop/active` in one call, then `rm -rf .loop` in the next. A **subpath** is
  unaffected (`.loop/state.md` was never guarded and still isn't), and once the
  loop is over the single command goes through unchanged. Humans keep
  `LOOP_ENG_DISABLE_EVIDENCE_GATE=1`.
- **`install-timer.sh` now runs `claude --version` under the unit's own PATH
  before writing anything.** Resolving the binary was never the same as proving
  it runs: `command -v` searches the installing shell's PATH while the unit
  hardcodes a minimal one, so an npm/nvm `#!/usr/bin/env node` shim resolved
  cleanly and exited 127 at 03:00 with the error only in `cron.log`. A failed
  probe refuses the install and prints the exact command to reproduce it.
  `LOOP_ENG_TIMER_SKIP_PROBE=1` is the way past it for a binary whose
  environment the probe cannot reproduce.
- **`unattended-polish.sh --auto-fix` now exits 70 instead of 0 when its result
  is not trustworthy.** `claude -p` exits 0 whether the session converged,
  stopped on a regression, or ran out of turns mid-edit. The driver now
  establishes the two facts it can for itself: the tree must be clean
  afterwards, and an optional project command in the new `LOOP_ENG_POST_CHECK`
  must pass. 70 is `EX_SOFTWARE`, distinct from the session's own status, which
  is still passed through untouched. The tree is left exactly as the session
  left it — reverting a half-applied fix would destroy the evidence on the one
  run that needs looking at. Report-only is exempt.
- **The autoloop driver's circuit breaker grew a second arm.** The existing one
  is keyed to commits, which answers "did anything happen" and not "did the
  backlog move": a session that commits real work and leaves its line unticked
  reset the counter, so one item could consume the entire session cap with
  every session logged as progress (reproduced at 8/8). It now also stops after
  `LOOP_ENG_MAX_ITEM_SESSIONS` sessions (default 2) on the same item. Set it to
  `0` for an item that legitimately spans sessions.

### Changed

- **`/polish` converges on deferred findings instead of re-confirming them
  every round.** A finding deferred under the public-contract stop rule is by
  definition never fixed, so nothing moves it out of the code — and with a line
  number in the dedup key it re-entered as "fresh" after every fix round that
  shifted lines above it, was re-verified into the same CONFIRMED verdict, and
  was deferred again. It burned a verifier pass per round and kept the loop
  alive on a finding it had already decided not to act on. Deferrals now go to
  `.loop/polish-deferred.md` keyed `file|summary` without the line — the one
  class where line-less dedup cannot lose a real finding, because the outcome
  is fixed in advance. The dry-round test now asks whether anything entered the
  FIX QUEUE rather than whether anything was confirmed, which is what the stop
  rules already said and Phase 2 did not.
- **The checker now reads `.loop/criteria.tsv`, the contract that actually
  runs.** Verify commands had two sources of truth — `contract.md` for the
  checker, `criteria.tsv` for the gate — both model-written, with nothing
  binding them, so a round could go green against one while the other decided
  otherwise. `criteria.tsv` wins because it is the file the stop-gate executes
  and `all_green` is computed from it alone; a disagreement is now itself a
  reportable finding.
- **`/autoloop` step 3 reconciles the report against the ledger before ticking
  a box.** A checker report is a claim and `results.json` is a run; there was
  no branch for "report green, ledger red", so the disagreement would surface
  as a blocked stop with no round left to fix it in. Step 3 now refreshes the
  ledger, treats any red criterion belonging to the current item as a failed
  round whatever the report said, and treats `malformed_lines` or `error` as
  never-green. The wrap-up's separate refresh is gone — it is this one.
- **The contract template's fast subset no longer ships `npm test`.** The
  stop-gate runs that subset on every stop attempt under a 100s budget; a
  typical JS suite overruns it, three fail-closed timeouts reach the 3-block
  ceiling, and ALL GREEN can then never be machine-confirmed at all. The
  examples are scoped commands, and the unscoped one sits in the block already
  labelled "final round".
- **The three judgment agents no longer claim "no write access by design".**
  They have no Write or Edit tool — that half is real and enforced by the tool
  whitelist — but they all have Bash, which writes. The prompts now say the
  enforced part as enforcement and the rest as the red line it always was.
  README's safety table gains the orchestrator row it was missing: it runs in
  your session with `Write` and `Bash`, and what is mechanical about it is that
  the evidence ledger is denied to it by the same hook as to everyone else.
- **A tag push now runs a release gate.** `.github/workflows/release.yml` fires
  on `v*`: it re-runs the full test matrix against the *tagged* tree (by calling
  `test.yml`, so there is one definition of "the suite" rather than two that
  drift) and asserts that the three manifest version fields, the CHANGELOG's
  dated section and the tag all say the same thing — plus that no
  `## Unreleased` was left behind. A tag whose manifests disagree with it
  installs cleanly and then serves the wrong version forever, and until now the
  only thing comparing them was a line in a checklist. The gate has
  `contents: read` and **publishes nothing**: `gh release create` stays a
  person's step, and so do RELEASING.md's live-install smoke and post-ship
  identity diff. CI's `npm i -g @anthropic-ai/claude-code` also gets three
  attempts with a backoff, so a registry blip cannot be what turns the manifest
  gate off.
- **The shellcheck gate moves from `-S error` to `-S warning`.** Thirteen
  warnings sat unchecked behind it and they were not cosmetic: nine were SC2164,
  a `cd` with no `|| exit` — in a *test* suite, where a failed `cd` into the
  sandbox means the remaining assertions run in the real working tree and start
  deleting `.loop/` files there. The rest were `$?` read from a condition
  instead of a command (SC2319, a live trap once the gate rises) and two
  unused-looking variables. All thirteen are fixed; the two deliberate
  exceptions carry an inline `# shellcheck disable=` with a reason. `-S style`
  stays out — SC1091 alone is 12 hits with nothing to fix.
- **Three README sections that restate repo facts now derive from them.** The
  env-var table was missing `LOOP_ENG_PLUGIN_CACHE_DIR`; the layout block named
  two of four `hooks/` files and called six `skills/loop-eng/scripts/` entries
  "unattended runner"; and two paragraphs disagreed about how many scripts hold
  the bash-3.2 floor (four in one, five in the Requirements table — five is
  right, and `update-notify.sh` was the one going unmentioned even though a
  SessionStart hook is precisely what stock macOS bash 3.2 runs in every real
  session). `test-packaging.sh` now reads the source of truth for each —
  `git ls-files`, the scripts' own `LOOP_ENG_*` reads, and the list
  `test.yml`'s bash-3.2 leg syntax-checks — so the next addition is covered the
  day it lands rather than the day someone remembers.
- **`.loop/state.md` says out loud that nothing reads it.** Its `Status:` line
  looked like a completion signal and is prose — no hook, script or gate has
  ever read this file. It is now labelled advisory, with the machine answer
  named (`results.json`'s `all_green`, and the ticked boxes) and the tie-break
  stated: if the two disagree, the ledger is right and state.md is stale. The
  template also gains the `## Deferred (not loopable)` heading the roadmap
  triage step has always told the orchestrator to write here.
- **`allowed-tools` lists `Agent` alongside `Task`.** The subagent tool's
  current name is `Agent`; `allowed-tools` is a pre-authorization list, so
  naming only the old one costs a permission prompt on every dispatch in
  interactive mode. `claude plugin validate` does not check tool names, so
  nothing else would have caught it.

### Fixed

- **Every scratch directory a test suite creates is now in its EXIT trap, and
  `test-harness.sh` checks that statically.** Two suites cleaned theirs with an
  inline `rm` a killed run never reaches, and one of those used a bare
  `mktemp -d` with no name pattern, so it did not even appear in a
  `loop-eng-*` scan of `$TMPDIR`. The scan found more than the audit did: the
  two unattended suites re-install a longer trap beside each new sandbox, a
  hand-maintained list that had already dropped `$SBG`/`$SBG2` once and `$SB9`
  again — and only the last trap installed is the one that runs. The check has
  two halves for that reason: every scratch variable must appear in *some* trap,
  and in the *final* one.
- **`sync-local.sh` prunes before it copies.** `commands/`, `agents/` and
  `hooks/` were copied over and never cleaned, so a file deleted or renamed at
  the root kept its stale copy in `.claude/` — the tree that actually loads
  while working in this repo, which then went on registering a command or hook
  the plugin no longer ships. `skills/` already did this; the other three did
  not. `.claude/settings.json` is still never touched.
- **`SKILL.md` gave both loops `/autoloop`'s bounds.** "Six stop rules bound
  every loop at 5 rounds max" was wrong about `/polish`, which has four stop
  rules and three macro rounds.
- **A failed update check now backs off for an hour instead of retrying every
  session.** Every failure path in the notifier — no connectivity, a 403, an
  empty body, a tag it cannot compare — exited above the state write, so
  nothing recorded that an attempt had been made and an offline machine paid a
  3-second `curl` at the start of every session, forever, with no trace of why.
  The state file gains a `last_fail` stamp; a success still silences the
  network for 24h, a failure for 1h. One hour rather than reusing the 24h
  window: a flight should cost one call, a transient blip should not cost a day
  of notices. A pre-release tag (`v1.3.0-rc1`) still produces no notice —
  announcing "1.3.0 is available" for a release that is not 1.3.0 would be
  wrong — but is now recorded as an attempt rather than silently discarded.
- **`uninstall-timer.sh` now stops the `.service`, not only the `.timer`.**
  systemd's `--now` applies to the unit it is given, so uninstalling at 03:05
  removed the schedule and left that night's `bypassPermissions` session running
  against the tree the operator had just unscheduled. The timer is still
  disabled first, so nothing can trigger a fresh run in the gap.
- **A double-registered Stop hook no longer costs two blocks per stop attempt.**
  Listing the loop-eng hooks in a project's `.claude/settings.json` while the
  plugin is also installed fires the gate twice, serially, and each invocation
  read the counter the previous one had just written: the 3-block ceiling
  arrived on the second attempt. The half that was never written down is worse —
  the ceiling clears `gate-count` on its way to allowing, so the twin read 0,
  re-ran the red contract and exited 2, meaning under double registration the
  ceiling never actually released the stop. The gate now records its verdict in
  `.loop/gate-last` and replays it for a repeat invocation arriving within
  `LOOP_ENG_GATE_DEDUP_WINDOW` seconds (default 1 — one second is the smallest
  window that survives `date +%s`'s own resolution). A marker that is
  unparseable, dated in the future, or older than the window is ignored rather
  than honoured; `0` disables the replay.
- **A UTF-8 BOM on the first line of `criteria.tsv` no longer renames the first
  criterion.** An editor that writes one put `EF BB BF` in front of the first
  id, so the ledger reported an id nobody authored and its evidence landed in
  `evidence/_<id>.log`. Nothing failed, which is why it survived: the contract
  still went green, and the mismatch only surfaced when a human looked the
  criterion up by name. Stripped on line 1 in `run-contract.sh` and in both of
  `arm-contract.sh`'s parse loops, so arm and run keep naming the same id — the
  same agreement the empty-description TAB split was fixed to preserve.

**Live-install smoke: PASS** (Claude Code 2.1.278, headless, throwaway
`CLAUDE_CONFIG_DIR`, GitHub-source marketplace install of this release's own
content on `main` — so no source-type disclosure is owed). The live **cache**
copies were instrumented before the run, so every verdict below is a marker on
disk rather than a model report:

- **evidence-gate**: `deny()` fired twice in one session — once for the `Write`
  (`EGDENY: raw evidence under .loop/evidence/`) and once for the Bash fallback
  the model reached for next (`a Bash command writing to the .loop evidence
  ledger`). `.loop/evidence/smoke.log` never landed. The marker also records
  `CLAUDE_PLUGIN_ROOT` as seen by the hook process: the real absolute
  `plugins/cache/loop-eng/loop-eng/0.16.0` path, not the `<loop-eng plugin root>`
  placeholder — so `hooks.json` auto-loaded and the variable reaches hooks.
- **arm-contract**: `armed from …/plugins/cache/loop-eng/loop-eng/0.16.0/…`, the
  version-pinned copy that enforces, not the `plugins/marketplaces/` clone.
- **stop-gate**: exactly three `SGBLOCK` markers (= `MAX_BLOCKS`) on a red
  contract, **then `CEILING-RELEASE`** — the first live evidence that the ceiling
  actually releases the stop, which is the half of the double-registration bug
  above that nobody had written down. `.loop/results.json` was machine-written by
  `run-contract.sh` with `"all_green": false`.
- **`${CLAUDE_PLUGIN_ROOT}` in command bodies**: `/loop-eng:autoloop` armed,
  reached ALL GREEN in round 1/5, and left a two-criteria ledger with
  `"all_green": true`.

One thing the last step demonstrated without being asked to: the session's own
closing report stated that `.loop/active`, `.loop/gate-count` and
`.loop/criteria.sha256` "remain in place", and all three were already gone —
the green path had cleared them. The report was a claim, the disk was the fact,
and they disagreed on the very run that proves the mechanism works. That gap is
the whole reason the ledger is machine-written.

## 0.15.0 — 2026-09-20

Everything the 2026-09-20 production-readiness audit rated P0 or P1, fixed with
a reproduction first and a failing assertion before each change. Suite 477 → 600
assertions across 13 suites (a new `tests/test-harness.sh`); the six
bash-3.2-floor suites re-verified under a real 3.2.57. Minor, not patch: several
user-visible defaults change below.

**Upgrade note — read this if you schedule the unattended drivers.**

- **Two timers on one repo at the same minute is now refused at install time.**
  Both modes default to `--time 03:00`, and the drivers cannot share a working
  tree. If you run both timers against one repo today, `install-timer.sh` will
  refuse the next re-install of the second one. Action: re-run it with a
  different time (`--time 04:00`). Nothing breaks until you re-install; existing
  units keep running, and from this version the loser simply exits 69 instead of
  editing the tree underneath the winner.
- **Two new exit codes.** `69` (`EX_UNAVAILABLE`) = another driver holds the
  repo lock; `143` = the driver was signalled and terminated its session.
  Deliberately distinct from the `75` these drivers use for provider limits.
  Action: if you alert on non-zero exits, decide which of these are noise.
- **A failure is no longer reported as a provider limit just because the code it
  was working on mentions one.** Runs that used to exit `75` ("try again later")
  now surface their real exit code, and `124` is reported as the timeout it is.
  Action: monitoring that keyed on `75` will start seeing the true failures it
  was masking.
- **`unattended-polish.sh` sessions are now actually killed at the budget**
  (`timeout -k 30`, which its autoloop sibling always had). A session that
  ignores SIGTERM no longer runs past `LOOP_ENG_MAX_MINUTES`.
- **Contributors:** `tests/test-manifest.sh` and `tests/test-hooks-json.sh` now
  FAIL on a host with no `python3`/`jq` instead of reporting `0 passed, 0
  failed` and exiting 0. Action: install either one. CI has both on all legs.

Revert path: pin `0.14.0` in your marketplace entry. Every new behavior above is
in the drivers, the installer or the test harness — no `.loop/` on-disk format
changed, so moving between the two versions needs no migration.

**Live-install smoke: PASS** (Claude Code 2.1.278, headless, throwaway
`CLAUDE_CONFIG_DIR`, GitHub-source marketplace install of this release's own
content on `main` — so no source-type disclosure is owed). Each step asserted on
state the mechanism writes, with the live **cache** copies instrumented so the
verdicts are machine facts rather than model reports:

- **evidence-gate**: the instrumented `deny()` fired (`EGDENY: raw evidence under
  .loop/evidence/`), the file was not created, and the denial names the real
  absolute runner path under `plugins/cache/.../0.15.0/` rather than the
  `<loop-eng plugin root>` placeholder — so `hooks.json` auto-loaded and
  `CLAUDE_PLUGIN_ROOT` reaches hook processes.
- **arm-contract**: `armed from …/plugins/cache/loop-eng/loop-eng/0.15.0/…`, the
  version-pinned copy that enforces, not the `plugins/marketplaces/` clone.
- **stop-gate**: exactly three `SGBLOCK` markers (= `MAX_BLOCKS`) on a red
  contract, and `.loop/results.json` machine-written by `run-contract.sh` with
  `"all_green": false`.
- **`${CLAUDE_PLUGIN_ROOT}` in command bodies**: `/loop-eng:autoloop` armed,
  reached ALL GREEN in cycle 1/5, lifted the gate itself, and left a two-criteria
  ledger with `"all_green": true`.

One observation worth keeping, and the reason the dispatch guidance above was
rewritten rather than deleted: on this run **both subagent dispatches detached to
the background** despite the synchronous request, costing two extra turns and
producing one duplicate (read-only) checker dispatch. The 0.14.0 smoke saw
synchronous dispatch on this same CLI version, so it is not a stable property.
It did not produce a false green — the ledger stayed machine-written throughout,
which is the guarantee that does not depend on dispatch semantics.

**Test blind spot: a safety default could be deleted and the suite stayed
green.** Both unattended drivers hand `claude` an argv that *is* their entire
contract with the session, and the stub in each suite ignored it. Measured, not
argued: deleting `$MODE` from `unattended-polish.sh`'s `-p "/polish $SCOPE
$MODE"` — so every scheduled run auto-fixes the repo under `bypassPermissions`
instead of reporting — kept `tests/test-unattended-polish.sh` at 39 passed / 0
failed. Swapping `/autoloop` for `/polish` and `bypassPermissions` for `default`
in `unattended-autoloop.sh` kept its suite at 41 passed / 0 failed. `report-only`
is that driver's only write protection, and nothing was watching it.

Both stubs now record their full argv (`STUB_ARGV_LOG`, one argument per line)
and each suite asserts what actually goes out: the command, the scope, the
`report-only` default and its removal only under the two-key `--auto-fix` +
`LOOP_ENG_ALLOW_AUTOFIX=1` opt-in, `--permission-mode bypassPermissions`, and
the per-driver turn cap (120 / 150). Each refusal path is asserted to invoke no
session at all, rather than merely to exit non-zero. Suite 477 → 490 assertions;
the two mutations above now fail 1 and 2 assertions respectively.

No runtime script changed here — this is the gate that was missing, not a
behavior fix.

**A suite that ran no assertions is no longer reported green.**
`tests/test-manifest.sh` needs `python3` and `tests/test-hooks-json.sh` needs
`jq` or `python3`; on a host with neither, each printed `0 passed, 0 failed`,
exited 0, and `run-all.sh` printed ALL GREEN for a run that checked nothing
about the two manifests or about `hooks.json`. Reproduced with a PATH holding
neither parser. `lib.sh`'s `report()` now fails when `PASS` and `FAIL` are both
zero, and the new `tests/test-harness.sh` pins that contract — including that an
all-red suite (`PASS=0`, `FAIL>0`) still fails for the ordinary reason — plus
the consequence itself: both parser-dependent suites are run under that
restricted PATH and asserted to exit non-zero. **Upgrade note for contributors:**
on a box without `python3`/`jq` those two suites now go red instead of quietly
passing. Install either one; CI already has both on all three legs.

**The stop-gate's green path clears three files, and only one was watched.**
Removing `"$SHA_LOCK"` and `"$COUNT_FILE"` from `hooks/stop-gate.sh`'s green
`rm` kept `tests/test-stop-gate.sh` at 33 passed / 0 failed. Both leftovers bite
the *next* loop: a stale `criteria.sha256` locks a contract that no longer
exists, so the next arm's `criteria.tsv` fails the hash check and every stop
after it exits 77 "tampered"; a stale `gate-count` starts that loop partway to
the 3-block ceiling. The green-path test now arms both files first — the first
draft asserted their absence over files the setup had already deleted, so it
passed against the very mutation it was written to catch — and asserts all three
are gone. Suite 490 → 504 assertions across 13 suites.

**A criterion could delete the criteria that came after it, and the ledger said
ALL GREEN.** `run-contract.sh` streamed `criteria.tsv` with `while … done <
"$CRIT"`, so a criterion that truncated or rewrote that file made every line
after it vanish mid-read — silently, at EOF. Not "skipped", not "malformed":
absent.

```
printf 'one\ttruncates\t: > .loop/criteria.tsv; true\ntwo\tred\tfalse\n' > .loop/criteria.tsv
→ exit 0, results.json holds only "one", "all_green": true
```

The authored contract's second criterion was `false`. Neither the vacuous guard
nor the partial-parse guard can see this, because from their side the contract
simply *was* one line — which makes it the one gap in "`passes: true` can only
come from running the command".

Two halves, mirroring the two questions a ledger has to answer. **What ran:**
the criteria loop now reads a private snapshot taken after the hash check, so
the executed set is the set that was read and (when armed) hash-verified,
whatever the commands do to the file afterwards; an appended criterion is not
executed by the run that appended it. **Whether the result may be reported:**
when the loop is armed with a hash-lock, `criteria.tsv` is re-hashed *after* the
last criterion and a mismatch writes a tampered ledger and exits 77. That
post-run check is gated on "a lock was checked at start", not on the lock still
existing, so deleting `criteria.sha256` mid-run is not a bypass.

`run-contract.sh` now needs `cp` alongside the `mv`/`rm`/`mkdir`/`cut`/`date`/
`tail`/`sed` it already required; both restricted-PATH fixtures list it. Suite
504 → 517 assertions; 9 of the 13 new ones fail against the pre-fix runner.

**A criterion with an empty description bricked the loop that armed it.**
`id<TAB><TAB>cmd` is three real TAB-separated columns with a blank middle one.
`IFS=$'\t' read -r id desc cmd` looks like the right spelling and is wrong in
one silent way: TAB is IFS *whitespace*, so bash collapses runs of it — the line
came back as `desc=cmd`, `cmd=""`, i.e. malformed.

`arm-contract.sh` carried **four** different splits of that same line: two
`awk -F'\t'` (which does not collapse) and two `IFS=$'\t' read` (which does).
They disagreed here and only here. The awk pair called the line runnable, so
arming warned about nothing and pinned the hash; the two read loops saw an empty
command and skipped it, so neither the static parse check nor the red-check ever
looked at it; and `run-contract.sh`, reading it the collapsing way, called it
malformed and failed **closed on every stop** — with a message blaming SPACES in
a file that contains none. The evidence-gate had locked `criteria.tsv` by then,
so the loop could only end by hitting a stop rule.

Both scripts now split on the **first two TABs**: everything after the second is
the command, an empty description is legal, and fewer than two TABs / an empty
id / an empty command is malformed. Five parse sites became two (one per
script). Both malformed messages now state that rule instead of asserting a
cause the runner cannot observe. Verified under real bash 3.2.57 (the CI floor)
as well as 5.x. Suite 517 → 533 assertions; 7 of the new ones fail against the
pre-fix scripts.

**Killing an unattended driver left its `claude` session running.** Neither
driver had a `trap` (`grep -c trap` was 0 in both) and GNU `timeout` places
itself in its own process group, so `systemctl stop` on a host whose unit does
not cgroup-kill, a cron `kill <pid>`, or a hand-typed Ctrl-C killed the driver
and orphaned a `--permission-mode bypassPermissions` session — for
`unattended-autoloop.sh`, one that *writes code* — to run on to its own budget
with nobody watching it. Reproduced with a sleeping stub: driver dead, stub
alive.

Each session now runs in the background under an explicit `wait` (a foreground
child blocks trap dispatch, so a trap around one fires too late to act), with a
`TERM INT HUP` handler that TERMs the session, waits up to 10s, then KILLs it,
logs the interruption — with the pending-item count, for autoloop — and exits
**143** (128+SIGTERM) so a scheduler can tell an interrupted run from a failed
one.

**`unattended-polish.sh` gets the `-k 30` its sibling always had.** Plain
`timeout` sends TERM and then waits indefinitely if the child ignores it, so a
wedged session made `LOOP_ENG_MAX_MINUTES` advisory rather than a budget.

Suite 533 → 542 assertions; the orphan and kill-after assertions fail against
the pre-fix drivers.

**Two drivers could edit one working tree at the same time.** Nothing enforced
mutual exclusion: both passed the dirty-tree check (the tree *is* clean at that
instant) and both started a `bypassPermissions` session. Reproduced with two
concurrent drivers: 2 sessions started. `install-timer.sh` defaults **both**
modes to `--time 03:00`, so installing a polish timer and an autoloop timer on
one repo is the documented route to it.

Each driver now takes a lock in `.loop/` before starting a session: `flock`
where the host has it (the kernel releases it however the process dies), an
atomic `mkdir` with a pid-staleness check where it does not (stock macOS ships
no `flock(1)`; a driver killed with SIGKILL runs no trap, so the pid inside the
lock is what tells "held" from "abandoned"). The second driver exits **69**
(`EX_UNAVAILABLE`) and says so in the rolling log — deliberately not the `75`
these drivers already use for provider limits, so a scheduler alerting on 75
does not start alerting about its own second timer.

**Upgrade note — `install-timer.sh` now refuses a same-repo, same-minute
collision.** With the lock in place the tree is safe, but the collision becomes
*silent*: the losing timer does no work, every night, while `systemctl status`
stays green. Installing the second mode on a repo whose other timer already
runs at that exact time is therefore refused, naming `--time` and the
`uninstall-timer.sh` command as the two ways out. If you have both timers on one
repo at `03:00` today, re-run the installer for one of them with a different
`--time`. Two *different* repos at `03:00`, and the same repo at different
times, are both still allowed — the latter is how you run both.

**Two stop rules could stop a loop that was working, and a third could stop it
after one backlog item.** These live only in Markdown, so nothing caught the
contradictions.

*Stop rule 3* fired on a repeated **failure**, while `loop-builder.md` tells the
builder to fix exactly ONE root cause per round. A criterion with two
independent causes behind it is still red after the first is fixed — the failure
repeats while the work progresses — so the loop stopped saying "the builder is
guessing" about a builder that was not. "Same failure" also had no definition:
`file:line` moves with every edit above it, so the same defect reads as a new
failure and two defects at one line read as one. The rule now keys on the
builder's `Root cause:` line, a new required field in its report; the checker
prefixes each failure with the contract criterion id it came from, and
identifies failures within a criterion by the normalized assertion line.

*Stop rule 5* counted the checker's failure list, which `loop-checker.md`
instructs to merge per file — so the count tracked how defects were distributed
across files, not how many there were. It now counts RED criteria in
`.loop/results.json`, which is machine-written and unmerged.

*Step 3* said "if the checker reports `ALL GREEN`: stop", while the multi-item
section says the checker judges only the current round's item and lists the rest
as EXPECTED-RED. Read literally, round 1 of a five-item backlog ended the loop
and printed a wrap-up diff. It now ticks the item and moves to the next, and
finishes only when no `- [ ]` line remains. The round budget said four different
things across the file; it is now stated once: **5 rounds is the total for the
invocation, one item may take several, and the counter does not reset at item
boundaries** (stop rules 3 and 5 still do).

**The synchronous-dispatch mitigation named a parameter that does not exist.**
The prompt told the orchestrator to set `run_in_background: false`; the Agent
tool has no such input, so the instruction could not be carried out. It now
describes the dispatch shape the orchestrator actually controls — one subagent
per dispatch, awaited before anything else, no fan-out — states the cost when a
harness backgrounds them anyway (two dispatches per round against a 3-block
ceiling reaches it inside round 2, exiting with the gate still armed), and cites
the one harness where it was measured to be synchronous (CLI 2.1.278, the 0.14.0
smoke). Deliberately **not** fixed by teaching the stop-gate to skip blocks while
a marker file exists: that marker would be prompt-writable, and a bypass the
model can create is not a mechanism.

Nine grep assertions in `tests/test-packaging.sh` now pin these decisions — they
cannot prove a prompt works, only that these specific contradictions stay fixed.

**Three ordinary ways of typing a write slipped past the evidence-gate's Bash
pattern.** None is an evasion: `rm -rf .loop/evidence` (the trailing slash was
*required*, so the plain directory name — how anyone writes an `rm` — matched
nothing), `echo x >| .loop/results.json` (`>|` is the noclobber override, and
the verb group stopped at `>>?`), and `echo x > .loop//results.json` (a doubled
slash is the same path to every OS). All three are denied now, and the
evidence-directory name matches when followed by `/`, by end of line, or by
anything that cannot be part of a filename — deliberately *not* `\b`, which
counts `-` and `.` as boundaries and would newly deny `.loop/evidence-notes.md`
and `.loop/evidence.bak`, siblings that are not the ledger. Unchanged and still
stated in the header: indirection that hides the path from the command text
(`F=.loop/results.json; echo x > $F`) is out of scope for any regex; the
guarantee for that class is `run-contract`'s hash re-derivation.

**A failure was reported as a provider limit whenever the code under review
mentioned one.** "The grep only runs on failed runs, which bounds the
false-positive surface" was the stated reasoning, and it does not hold: a polish
session *reviews code*, so its log is full of the text under review. A stub
printing `checkQuota() { /* the quota is never reset */ }` and exiting 2 came
back as EX_TEMPFAIL **75** — "try again later" — and the real failure never
reached whatever watches exit codes. In the autoloop driver the same match also
parks the run in `sleep $((LIMIT_WAIT_MIN * 60))`: at the default, a full hour
of doing nothing before retrying a failure that will not fix itself.

Both drivers now match provider *phrases* (`usage limit reached`, `quota
exceeded`, `rate limit exceeded`, `rate_limit_error`, `overloaded_error`, `too
many requests`) in the last 40 lines of the log — a limit ends the run, so it is
the last thing written, while the body is the material under review — and never
on exit 124, which is our own wall-clock kill. 0.14.0's release notes recorded
that last case as a known consequence of enforcing the cap on macOS; it is fixed
here.

**A killed session left the gate armed, and that bricked every session after
it.** `.loop/active` is lifted by the stop-gate only when the contract goes
green; a session killed by the driver's own timeout, by a TERM, or by the
3-block ceiling leaves the file on disk with a clean tree. The next session then
tries to write its own `criteria.tsv` and the evidence-gate denies it — through
Write *and* through Bash, because that file is the armed contract — so it arms
nothing, verifies nothing, commits nothing. Two of those and the circuit breaker
opens, with only `NO new commits` in the log to explain a backlog that stopped
moving. Reproduced: DENIED on both write paths, then `circuit breaker OPEN`.

`unattended-autoloop.sh` now reclaims the leftover before its first session and
again after every session — after, because that is where a killed session's
leftover actually appears, and deferring it to the next driver run would cost
this run every remaining session. All three files go (`active`, `gate-count`,
`criteria.sha256`): a lone hash-lock makes the next arm's own `criteria.tsv`
read as tampered, a lone counter starts that loop partway to the ceiling. The
driver is the human-authorized outer layer — "the model must not disarm its own
gate" governs the session inside, not the scheduler that started it — so this is
its job, and doing it from the prompt would not be equivalent.
`commands/autoloop.md` Step 0 and README's resume bullet carry the manual form,
including the two-call ordering the evidence-gate requires.

**`.loop/` had to be gitignored for anything to work, and nothing made it so.**
README asserted the directory "is gitignored"; this repo's own `.gitignore`,
`tests/lib.sh` and `RELEASING.md` each hand-write the line, so the assumption
was known — the Install instructions just never stated it. In a project without
it, the builder's `git add -A` commits `criteria.tsv`, `criteria.sha256`,
`results.json` and `evidence/`; the stop-gate then rewrites `results.json` on
every stop, the tree is permanently ` M .loop/results.json`, and both unattended
drivers refuse to run ("dirty tree, refusing") from then on. Verified end to
end: five `.loop` files committed, then a wedged tree.

`arm-contract.sh` now checks at the start of every loop. Not ignored → the
directory is appended to `.git/info/exclude`, which is local and untracked, so
arming a loop never turns into a diff in someone's PR (idempotent: a second arm
appends nothing). Already **tracked** → no ignore rule can undo that, so it
warns and prints the `git rm -r --cached` command that does, and still arms —
stranding a loop over bookkeeping would be the worse trade. `commands/autoloop.md`
Step 0 checks `git ls-files .loop` for the tracked case, and README's loop-state
bullet now describes the guarantee instead of asserting the outcome.

Suite 542 → 600 assertions. Three pre-existing install-timer fixtures that
happened to stack both modes on one repo at `03:00` now pass `--time 04:00`;
they were testing uninstall symmetry and unit contents, not collisions.

## 0.14.0 — 2026-09-20

Two gaps this repo had already written down and left open: a wall-clock budget
that silently did not apply on macOS, and a bash-3.2 compatibility claim that
lived only in a code comment. Test suite 468 → 477 assertions (counted by
summing `bash tests/run-all.sh`, at the previous release commit and at this one).
The 0.13.0 entry's "456" is not wrong so much as early: `tests/test-packaging.sh`
landed later in that same cycle carrying exactly the missing 12, so a fresh count
of the v0.13.0 tree is 468. Both numbers here were measured, not carried forward.

**Behavior change, macOS only — read this if you schedule `/polish`.**
`unattended-polish.sh` probed only `timeout`, so on a mac with Homebrew
coreutils — where GNU coreutils installs the binary as `gtimeout` — a scheduled
polish ran with **no** wall-clock cap, while the autoloop driver and the
stop-gate, both of which fall back to `gtimeout`, stayed bounded. The probe is
now `timeout` → `gtimeout`, so on such a host a nightly polish is from now on
killed at `LOOP_ENG_MAX_MINUTES` (default **120 minutes**) where it previously
ran to completion. To keep long runs: raise `LOOP_ENG_MAX_MINUTES` (`0` is
refused and falls back to 120 — `timeout 0m` means "no limit", which is the
opposite of what a budget knob's lowest value should do), or pin 0.13.0. A host
with neither binary still runs uncapped, but now says so on stderr, where the
scheduler's own log keeps it, instead of dropping the budget in silence. Linux
is unaffected: `timeout` was always found there.

One known consequence of the cap being live on macOS, surfaced by the pre-ship
review and deliberately left as-is: a polish run the cap kills exits 124, and if
its partial log happens to carry a provider-limit word (`quota`, `overloaded`),
this runner's rate-limit branch reports EX_TEMPFAIL 75 — "try again later" —
rather than a timeout. The autoloop driver distinguishes 124 explicitly; this one
does not yet. Pre-existing logic with a bounded false-positive surface (the grep
runs only on failed runs), newly reachable here, and a fix would be its own
change rather than a line in a release.

**`update-notify.sh` joins the bash-3.2 CI leg.** It is a SessionStart hook, so
on a stock macOS box it is bash 3.2 that runs it in every real session — and the
only thing asserting it could was a comment in its own header, while README said
outright that the `test-bash32` job did not cover it. That job now runs six
suites and syntax-checks six scripts. Verified under a real 3.2.57 before
wiring, via CLAUDE.md's docker recipe (extended to the same six suites): all six
green, `test-update-notify` 26 passed / 0 failed, and the six-script `bash -n`
list parses. musl is not BSD, so the macOS cell is the one the CI leg adds.
`tests/test-update-notify.sh` also stops resolving `bash` from PATH when it runs
the hook and uses `$BASH`, the interpreter running the suite: under the 3.2 leg a
5.x homebrew bash that happened to be installed would otherwise have run the
hook, and the leg would have reported a 3.2 verdict it never tested.

Evidence for the polish fix, in the order it happened:
`tests/test-unattended-polish.sh` 30 → 39 assertions. Run against the pre-fix
driver, exactly the arms carrying the fix fail and everything else passes —
35 passed / 2 failed for the gtimeout arm and the stderr-warning arm, and later
38 / 1 for the rolling-log assertion the pre-ship review added. Post-fix: 39 / 0.
The both-installed arm passed throughout, which is what proves the harness rather
than the fix. Both absent-binary arms run the driver under a minimal bin dir of
symlinks to exactly what it and the stub exec, because no real PATH can be made
to lack `timeout` on demand; each prerequisite symlink is asserted, so a missing
one cannot masquerade as a driver bug.

Docs: the README Requirements table drops its "Known, not yet fixed" admission,
and its intro names the guard-weakening rows correctly — rows 1-4, not "1-3 and
5", which counted `curl` (a missing notice, not a guard) and skipped the polish
timeout row.

**Live-install smoke** (RELEASING.md §1, against this release's content): PASS on
Claude Code 2.1.278, via a genuine `claude plugin marketplace add sdsrss/loop_eng`
+ `claude plugin install` into an isolated `CLAUDE_CONFIG_DIR`. A GitHub source,
so the copy that enforced is the version-pinned
`plugins/cache/loop-eng/loop-eng/0.14.0/` one and not the marketplace clone —
both existed, and `arm-contract` printed `armed from` that cache path. No
source-type disclosure is owed this time: 0.14.0 was on `main` before the smoke
ran, which is what makes `marketplace add owner/repo` install the release's own
content.

Machine-verified rather than model-reported, by instrumenting the live cached
hooks. Step 4: `DENY-FIRED … root=<the real cache path>` — not the
`<loop-eng plugin root>` placeholder, so `CLAUDE_PLUGIN_ROOT` reaches hook
processes — and `.loop/evidence/smoke.log` did not land under
`--permission-mode bypassPermissions`. Step 5: `BLOCK-exit n=0..2` then
`CEILING-RELEASE count=3` over a `generated_by: run-contract.sh` ledger reading
`all_green: false` with the `red` criterion false, while `.loop/evidence/red.log`
was written by the runner — the same directory the model had been denied a moment
earlier, which is the whole invariant in two steps. Step 6: a full
`/loop-eng:autoloop` round reached `all_green: true` on both criteria, `hello.txt`
held `hi`, and `.loop/active` + `.loop/criteria.sha256` were removed by the gate
rather than by the model. Reachable only if `${CLAUDE_PLUGIN_ROOT}` expanded
inside the command markdown. That session's own closing summary asserted
`.loop/active` was "still armed"; the disk said it was gone. The disk is the
authority here, which is the point of the plugin.

**Post-ship smoke** (RELEASING.md §3, against the RELEASED v0.14.0 in a second,
fresh `CLAUDE_CONFIG_DIR` with no instrumentation): PASS. The installed cache tree
is byte-for-byte identical to the `v0.14.0` tag — `diff -r` between
`git archive v0.14.0` and `plugins/cache/loop-eng/loop-eng/0.14.0/` reports only
the platform's own `.in_use` marker — so what a user installs is the tag, not a
neighbouring commit. On that untouched copy: a model write to
`.loop/evidence/postship.log` did not land, `arm-contract` armed from the new
cache path, and a red contract produced `generated_by: run-contract.sh` /
`all_green: false` with `.loop/evidence/red.log` written by the runner.

**Pre-ship review** (independent reviewer, fresh context, over `dcf2745..9b9f62f`):
every numeric claim above re-measured, including under a real 3.2.57; no blocking
finding; six accepted repairs. Two were load-bearing. The new UNBOUNDED warning
went to stderr only, and this script's own cron example ends `>/dev/null 2>&1` —
so the warning was discarded by the very invocation it is written for, leaving a
plain `exit=0` in `.loop/unattended.log` for an uncapped run, and making the
"where the scheduler's log keeps it" line above false for anything but the systemd
path. It is now tee'd into the rolling log, like the dirty-tree refusal. And the
`test-bash32` leg's "Prove /bin/bash is stock 3.2" step printed the version
without asserting it: a runner image that ever ships a newer `/bin/bash` would
have kept that leg green while testing the wrong interpreter — the same
silent-disarm shape this release's other half exists to close. It now fails the
job unless `BASH_VERSINFO[0]` is 3. Four smaller ones: README's "each says so"
now excludes `arm-contract.sh`'s advisory red-check (which really does just run
unbounded), the env-var table stops crediting `timeout` alone for the budget, the
both-installed arm asserts that exactly one wrapper ran rather than trusting a
substring on an append-only record, and the minimal-bin-dir comment names
`/usr/bin/env` as the one prerequisite no symlink can cover.

## 0.13.0 — 2026-09-19

New-user lifecycle QA: install → use → update → self-heal → uninstall, driven
end to end against a genuine `claude plugin marketplace add sdsrss/loop_eng`
install into an isolated `CLAUDE_CONFIG_DIR` on Claude Code 2.1.278. The
enforcement layer passed every leg on the real artifact — evidence-gate denied
a `Write` to `.loop/evidence/` with `CLAUDE_PLUGIN_ROOT` resolved to the cache
path, the stop-gate blocked a red contract and machine-wrote
`"generated_by": "run-contract.sh"` / `"all_green": false`, `/autoloop` armed
via `${CLAUDE_PLUGIN_ROOT}` and reached ALL GREEN, the hash-lock caught a
post-arm rewrite (exit 77), and a runner deleted from the cache produced the
fail-closed block that names `/plugin update loop-eng`. What the sweep found
was on the edges: one packaging defect, three places where a real environment
dependency lived only in a code comment, one quiet corner of the hash-lock, and
two release-blocking facts that were checklist lines rather than tests. Test
suite 411 → 456 assertions.

**Release smoke** (RELEASING.md §1, re-run against this release's content at
0.13.0 after the version bump; the earlier 0.12.2 run is superseded rather than
carried over, because a smoke that names a version has to have run on it): PASS
on Claude Code 2.1.278, machine-verified rather than model-reported. Step 4 —
the model's `Write` to `.loop/evidence/smoke.log` was DENIED, the file did not
land under `--permission-mode bypassPermissions`, and an instrumented `deny()`
logged a real `root=` path rather than the `<loop-eng plugin root>` placeholder,
so `CLAUDE_PLUGIN_ROOT` reaches hook processes. Step 5 — a `false` criterion
blocked the stop (`BLOCK n=1`) and `run-contract.sh` machine-wrote
`"all_green": false`. Step 6 — a full `/loop-eng:autoloop` round reached
`"all_green": true` on two criteria, `hello.txt` held `hi`, and `.loop/active`
and `.loop/criteria.sha256` were removed by the gate rather than by the model,
which is reachable only if `${CLAUDE_PLUGIN_ROOT}` expanded inside the command
markdown.

Source-type disclosure, owed by the rule this release adds to RELEASING.md §1:
the marketplace was added by local path, because 0.13.0 was not yet pushed and
`marketplace add owner/repo` can only take the default branch. The instrumented
markers named the source copy, confirming it enforced while the version-pinned
`plugins/cache/` copy did not — exactly what that new rule predicts, verified on
its first two uses. The GitHub-source path, which is the one real users get, is
re-smoked against the released tag per §3 Post-ship.

**Post-ship smoke** (RELEASING.md §3, against the RELEASED v0.13.0 via
`claude plugin marketplace add sdsrss/loop_eng` into a fresh isolated
`CLAUDE_CONFIG_DIR`): PASS. This is the run that covers the path the §1
disclosure above could not — with a GitHub source the instrumented marker came
back `CACHE-DENY` naming `plugins/cache/loop-eng/loop-eng/0.13.0`, so the
version-pinned copy is what enforces for real users, and the model's `Write`
to `.loop/evidence/` was denied with no file on disk. The release artifact also
carries this batch's packaging fix: `install-timer.sh` and `uninstall-timer.sh`
are `-rwxr-xr-x` in the installed cache, and README's bare-path invocation
prints usage instead of `Permission denied`. `contract_lock` behaves as
documented on the released build — absent from the ledger on a locked run,
present with the warning once the lock is removed.

**Pre-ship review**: an independent reviewer with no authoring context returned
SHIP with no BLOCKER, having driven every fail-closed exit in a sandbox (78
missing criteria, 77 post-arm tamper, 77 locked-with-no-SHA-tool, 73 unwritable
`.loop` and `.loop/evidence`, plus the stop-gate's block-ceiling, missing-runner,
timeout-124 and green-disarm paths) and mutation-tested both new suites. It also
raised one HIGH and six MEDIUM/LOW findings, all fixed above or recorded as
known. Three of those were absolute claims the author asserted without checking
what else could produce the state they named — the reason `author ≠ reviewer` is
a rule here and not a courtesy.

**fix: the two timer scripts shipped non-executable.** `install-timer.sh` and
`uninstall-timer.sh` were recorded in git as `100644`, while README documents
both as bare-path commands (`skills/loop-eng/scripts/install-timer.sh <polish|
autoloop> <repo>`). A marketplace install materializes the tree with its
recorded modes, so the first line a new user pasted answered `Permission
denied` — reproduced in the installed cache copy, not just the repo. Their two
siblings in the same directory, `unattended-polish.sh` and
`unattended-autoloop.sh`, were already `100755`, which is why the gap survived:
every test in the suite invokes these scripts as `bash <path>`, a form that
works at any mode, so nothing exercised the documented one. Now `100755`.

**test: `tests/test-packaging.sh`** (new, 12 assertions) closes that blind spot
by asserting the git-index mode of every script README invokes bare-path. The
candidate list is *derived* from README rather than written down — a runner
documented tomorrow is covered tomorrow — and the scan fails closed if its
pattern ever matches nothing, so the suite cannot go green while checking zero
files. It also pins the converse: `hooks.json` spawns every hook through
`bash "<path>"`, so hook modes are deliberately not part of the contract.

**docs: a Requirements table in README.** `jq`/`python3`, a SHA-256 tool,
`timeout`/`gtimeout`, `curl`, `systemctl`, and the bash ≥ 4.4 floor were each
probed at run time and documented only in the script that probes them. Two of
those absences silently weaken a guard, which is exactly the class that should
not live in a comment. Each row states what actually degrades; every claim was
grep-verified against the probing script.

**test: the parser-less evidence-gate is now pinned** (+2 assertions). With
neither `jq` nor `python3` the gate fails open — deliberate, since a PreToolUse
hook must never brick a session, but it was the one environment where the gate
looks installed and enforces nothing, and no test covered it. Both halves are
now asserted: the exit code stays 0, and the stderr warning that is a human's
only signal stays present. README states the consequence and its bound,
measured rather than reasoned: on a parser-less box a hand-forged
`{"all_green": true}` in `.loop/results.json` was overwritten by
`run-contract.sh` on the next stop attempt and the stop was still blocked
(exit 2). The evidence-gate is defense-in-depth; the stop-gate is load-bearing
and needs no parser.

**docs: two traps in RELEASING.md.** (1) The pre-flight now validates the
plugin manifest by path — given `.` the validator finds `marketplace.json`
first and reports `"contents": []`, a green that checked no command, agent, or
skill; the one expected `--strict` warning (root `CLAUDE.md`) is named so any
other is a blocker. (2) §1 now requires adding the marketplace by its GitHub
source: a `directory` source runs the plugin *from the source directory*,
leaves `plugins/marketplaces/` empty and never executes the version-pinned
`plugins/cache/` copy that every path in steps 3–4 points at. Confirmed by
running the same smoke once per source type with a marker in `deny()` in both
copies. Instrumenting the cache under a directory source yields an empty log
that reads exactly like "the hook never fired" — the fourth instance of that
family in these two steps.

**fix(run-contract): a missing hash-lock is no longer silent.** The integrity
check ran under `[ -f "$ACTIVE" ] && [ -f "$SHA_LOCK" ]`, so a missing
`criteria.sha256` skipped it entirely and a lockless run was indistinguishable
from a locked one — the corner where "weakening an armed contract can never
pass silently" stopped being true. Armed, no lock, and a SHA-256 tool present
now warns on stderr and stamps `"contract_lock": "absent"` into
`results.json`.

It reports the **state, not a cause**, and that distinction is this entry's own
correction: the first draft asserted that `arm-contract.sh` "drops the lock in
exactly one case" and told the reader to re-arm through it. Both halves were
wrong. `arm-contract.sh` omits the lock on two paths (no hashing tool, and no
`criteria.tsv` at arm time), and `commands/autoloop.md` documents a last-resort
arm that is a bare `touch .loop/active` — on which the warning fired every run
and prescribed re-running a script that path exists because it is unavailable.
Caught by the pre-ship reviewer, not by the author. The message now states only
what the code can observe: the tamper check did not run.

Deliberately a warning, not a refusal — every route to this state is
legitimate, and failing closed would strand a live loop whose only exit is
deleting `.loop/active`, trading a documented residual for a new way to lose
work. The ledger carries it because a green contract lets the stop-gate exit 0,
which discards hook output. Every arm of the branch is tested (+13 assertions),
including the two that must stay silent: a machine with no hashing tool, and
the documented `touch .loop/active` fallback, which must warn without
misdiagnosing.

**fix(unattended): the bash ≥ 4.4 floor is checked, not just stated.** Both
drivers carried "Requires bash >= 4.4" as a header comment and nothing else, so
on stock macOS bash 3.2 they STARTED, did real work, and only then died on the
first empty-array expansion under `set -u` — the worst shape for an unattended
writer, which for `unattended-autoloop.sh` may already have let a session
commit. They now refuse up front with exit 78 (EX_CONFIG) and a message naming
the requirement. Verified on real bash 3.2.57 via the docker recipe in
CLAUDE.md: both exit 78. A separate `BASH_VERSION` check runs first and stays
its own statement, because a non-bash shell dies on the array subscript in the
version test with a bare "Bad substitution" — the `:-0` default never applies,
since the failure is in the subscript syntax rather than the value. Found by
the pre-ship reviewer, who noticed the README row this batch added claimed a
guard that did not exist.

**docs: the Requirements table said things that were not so.** Same review. The
`timeout` row omitted the unattended drivers; `systemctl` omitted
`uninstall-timer.sh`; there was no row at all for the `claude` CLI, which
`install-timer.sh` hard-requires — a stronger dependency than three of the rows
that were listed. The table now also records an asymmetry it surfaced:
`unattended-polish.sh` probes only `timeout` and never falls back to
`gtimeout`, unlike its three siblings, so on macOS-with-coreutils a scheduled
polish runs uncapped while autoloop does not. Pre-existing, documented here,
not fixed in this release. The "(CI-tested)" claim is narrowed to the four
scripts `test-bash32` actually covers — `update-notify.sh` is a registered hook
and is in neither of that job's lists. The table's preamble, which promised
everything "degrades rather than failing", now says which rows weaken a guard
and which refuse outright.

**test: `tests/test-manifest.sh`** (new, 20 assertions) turns two RELEASING.md
checklist lines into failures. "A version bump touches THREE fields across TWO
files" was a thing a human remembered; now a drifted `metadata.version` or
`plugins[].version` fails the suite, as does a missing CHANGELOG section for the
shipped version. It also asserts every shipped component `.md` has frontmatter
(without one, a command loads as nothing and nothing fails), and that each
agent's `name:` matches its filename — the Task tool dispatches on that field,
and the platform validator does not check it. JSON is parsed by explicit path
with python3 and the marketplace entry is selected BY NAME: `plugins[]` is an
array, and a positional grep reads the wrong field the day a second entry
appears. Where the `claude` CLI is installed the suite also runs
`claude plugin validate` (credential-free, verified against an empty
`CLAUDE_CONFIG_DIR`) and asserts zero errors with the root-`CLAUDE.md` warning
as the only warning — strict-grade rigor without tripping on the one warning
the plugins reference documents as unavoidable and unsuppressable. Every
assertion was mutation-tested: bumping `plugin.json` alone, stripping a
frontmatter block, and typo-ing an agent name each turn the suite red.

**ci: the manifest gate is live on the Linux leg.** `npm i -g
@anthropic-ai/claude-code` on ubuntu only — manifest validity is
platform-independent, so paying for it on all three legs buys nothing, and the
validator needs no credentials. Not softened with `|| true`: an install that
failed quietly would switch the gate off while CI still reported green, the
silent-disarm shape this repo exists to refuse. Unpinned for the same reason a
plugin's verdict comes from the CLI its users run. `Show tool versions` now
prints `claude --version` so each run states whether the gate was live rather
than leaving it inferred.

**docs: CLAUDE.md no longer states the plugin cache is enforcing.** It claimed
loop-eng "is also installed as a marketplace plugin (user scope)" as
unconditional fact; on this machine it is not installed at all, which makes the
guidance a trap in the other direction — an agent assuming a stale cache
enforces will misread which copy it is testing. Now conditional, with the
one-line `claude plugin list` check, a pointer to `arm-contract.sh`'s
`armed from` line as the authority over any belief, and the directory-vs-GitHub
source distinction.

**docs: one file outlives an uninstall.** The update notifier's throttle stamp
at `${XDG_CACHE_HOME:-~/.cache}/loop-eng/update-check.json` sits outside
`~/.claude/` on purpose (so it survives a version bump rather than being
orphaned in the version-pinned cache), and `/plugin uninstall` does not know
about it. README now says so, with the one-line `rm` and what the file holds.

## 0.12.1 — 2026-09-19

Hardening batch. Nothing here changes what the enforcement layer decides: no
contract that passed before fails now, and no stop that was blocked is allowed.
Two of the three are the same defect shape — a hand-written roster standing in
for a set that should be derived from the source — which makes it this repo's
most frequent one. Test suite 394 → 411 assertions.

**Live-install smoke** (RELEASING.md §1): PASS on Claude Code 2.1.278, against a
genuine `claude plugin marketplace add sdsrss/loop_eng` + `install` of this
release's content into an isolated `CLAUDE_CONFIG_DIR`. Machine-verified, not
model-reported. The plugin resolved to
`plugins/cache/loop-eng/loop-eng/0.12.1/` and `arm-contract` printed `armed
from <that cache path>`. The release's own change was smoked directly: arming a
two-line contract whose second criterion is the 0.12.0 pathspec shape
(`:(exclude)…` unquoted) printed `criterion 'scope' can never run` with bash's
own diagnosis, while the legitimately-RED `false` criterion beside it drew no
such warning. An instrumented `evidence-gate.sh` logged `DENY-FIRED tool=Write
file=<proj>/.loop/evidence/smoke.log root=<real cache path>` and the file did
not land under `--permission-mode bypassPermissions`, so hooks.json auto-loaded
and `CLAUDE_PLUGIN_ROOT` reached the hook process. An instrumented
`stop-gate.sh` logged `BLOCK-red n=1..3` then `CEILING-RELEASE count=3` over a
`generated_by: run-contract.sh` ledger reading `all_green: false`. A full
`/loop-eng:autoloop` round then reached `all_green: true` on both criteria with
`.loop/active` and `.loop/criteria.sha256` removed by the gate rather than by
the model — reachable only if `${CLAUDE_PLUGIN_ROOT}` expanded inside the
command markdown.

One checklist defect surfaced and is fixed in RELEASING.md: step 3's
`find "$CACHE_ROOT" -maxdepth 3` cannot reach the runner, which sits five
components down at `<version>/skills/loop-eng/scripts/arm-contract.sh`. It
matched nothing and `bash "$ARM"` ran the empty string, which reads like a
broken install rather than a broken checklist line.

### Fixed
- **`arm-contract.sh` said nothing about a criterion that can never run.** The
  pre-arm red-check only warned when a criterion was ALREADY green. A criterion
  whose command is not valid shell stayed silent, and that is the worse case:
  `criteria.tsv` is hash-locked the moment the loop arms, so such a criterion
  can never go green and the loop can only end by hitting a stop rule. Not
  hypothetical — it is what the 0.12.0 live-install smoke recorded, where the
  orchestrator's `printf` ate the outer quotes off a git pathspec and left
  `:(exclude)…` bare.

  The check keys on the PARSE, not on an exit status. That shape exits 2, and so
  does `grep -q needle a-file-the-work-will-create`, which is a legitimate RED;
  126 and 127 are ambiguous the same way, since `bash tests/not-yet-written.sh`
  is 127 and a perfectly good criterion. `run-contract.sh` executes each
  criterion as `bash -c "$cmd"`, so `bash -n -c` is that same invocation's parse
  phase: a failure there is a property of the command string rather than of the
  tree, which is why it cannot be a false positive. It executes nothing, so it
  runs with the other static pre-arm warnings and is NOT governed by
  `LOOP_ENG_ARM_REDCHECK` (the knob whose whole purpose is to execute zero
  criterion commands). Advisory only: arming still succeeds.

- **`scripts/sync-local.sh` silently skipped a hook.** The dogfood sync named
  `stop-gate.sh` and `evidence-gate.sh` literally, so `update-notify.sh` was
  added to `hooks/` and never copied. The suite did not catch it because its
  fence was also a hand-written list, copied from a roster that was already
  wrong — one hand-written list standing guard over another, in the file whose
  own header calls it "the regression fence for that class". Both sides now
  derive from `hooks/*.sh`, and so does the executable-bit check. `hooks.json`
  stays out on purpose: it is the plugin auto-load manifest, read only at a
  plugin root, while `.claude/` is read as a project directory. Affects
  dogfooding inside this repo only; nothing a marketplace install consumes.

### Added
- The README's manual hook-registration snippet is now held equal to
  `hooks/hooks.json` by `tests/test-hooks-json.sh`. Its PreToolUse matcher was a
  hand-copied duplicate with nothing keeping the two in step, so adding a write
  tool to `hooks.json` would have left the registration the README tells users
  to paste silently under-matching — a weaker evidence-gate on a documented
  path. The gate states what it does not cover: that Claude Code honours the
  snippet at all (platform contract, live-install smoke only), the SessionStart
  notifier the snippet omits deliberately, and the timeouts it omits safely.
- README now says why the snippet omits the SessionStart hook and the timeouts
  rather than leaving both as silent gaps. A command hook without `timeout` gets
  the platform default of 600s, already above the stop-gate's own
  `LOOP_ENG_GATE_TIMEOUT` budget of 100s; and `Stop` has no matcher support, so
  the snippet's missing `matcher` is correct rather than an omission. Both facts
  were checked against the hooks documentation, after each had first been
  suspected of being a fail-open hole and turned out not to be.

### Tests
- Suite 394 → 411 assertions. `test-arm-contract` +12: five confirmed red
  against the unfixed script, the other seven driven red by three targeted
  mutations (warn unconditionally; drop the one-line fold of bash's diagnosis;
  `bash -n -c` → `bash -c`, which the zero-side-effect assertion catches).
- `test-sync-local` +1 with its hook fence re-derived from the source tree —
  both confirmed red against the unfixed script, naming `update-notify.sh`.
- `test-hooks-json` +4, each driven red by mutation: matcher drift from either
  side, a broken README snippet, and a wrong script path.
- Real bash 3.2.57 (docker `bash:3.2`): 247 passed / 0 failed across the five
  suites that run on the 3.2 axis.

## 0.12.0 — 2026-09-19

A convergence pass over the completion mechanism itself. Four defects of one
family: a place where the machine reported — or was one ordinary refactor away
from reporting — success over something it had not verified. Each was
reproduced against the real scripts in a sandbox before a line was changed, and
every new assertion was confirmed red against the unfixed code. Test suite
358 → 394 assertions.

**Live-install smoke** (RELEASING.md §1): PASS on Claude Code 2.1.278, against a
genuine `claude plugin marketplace add sdsrss/loop_eng` + `install` of this
commit's content into an isolated `CLAUDE_CONFIG_DIR`. Every check is
machine-verified, not model-reported: the plugin resolved to
`plugins/cache/loop-eng/loop-eng/0.12.0/`; `arm-contract` printed `armed from
<that cache path>`; an instrumented `evidence-gate.sh` logged `DENY-FIRED
tool=Write file=<proj>/.loop/evidence/smoke.log root=<real cache path>` and the
file did not land under `--permission-mode bypassPermissions` (so hooks.json
auto-loaded AND `CLAUDE_PLUGIN_ROOT` reached the hook process — no placeholder);
an instrumented `stop-gate.sh` logged three `BLOCK-red` entries followed by
`CEILING-RELEASE count=3` over a `generated_by: run-contract.sh` ledger; and a
full `/loop-eng:autoloop` round reached `all_green: true` and logged
`GREEN-SELFCLEAR`, with `.loop/active` and `.loop/criteria.sha256` removed by the
gate rather than by the model — reachable only if `${CLAUDE_PLUGIN_ROOT}`
expanded inside the command markdown.

One unplanned run during that smoke is worth recording, because it is the thesis
working: an earlier `/autoloop` attempt had the orchestrator author a criterion
whose git pathspecs lost their quotes to `printf`, leaving `:(exclude)…`
unquoted — a bash syntax error, exit 127, a criterion that can never go green.
The checker subagent reported ALL GREEN. The machine ledger said
`all_green: false`. The orchestrator took the ledger over its own subagent's
claim, declined to self-authorize `LOOP_ENG_DISABLE_EVIDENCE_GATE=1` to repair a
hash-locked contract mid-loop, and escalated to the human under stop rule 6.

**Upgrade note**: after updating run `/reload-plugins` or start a fresh session
— the hook-side changes take effect only once the plugin cache is on 0.12.0.
**One behavior change can strand an armed loop.** A `criteria.tsv` line that
misses the TSV shape used to be skipped in silence; it now fails the contract
closed. If you update while a loop is armed with such a line, the contract goes
red while the evidence-gate is holding `criteria.tsv` locked, so the correction
has to come from outside the loop: `rm .loop/active`, fix the line, re-arm.
Loops armed *after* the update cannot reach that state — `arm-contract.sh` now
warns about the same lines before arming, while the file is still writable.
Revert path: pin v0.11.0.

### Fixed
- **A partly parsed contract reported `all_green: true`.** The vacuous-contract
  guard fires only at ZERO runnable criteria, so between 1 and N−1 a line that
  yielded no id or no command column was skipped in silence — the contract ran
  fewer checks than its author wrote and still went green, and the dropped line
  is by construction the one nobody is watching. Reproduced with the slip that
  makes this likely, a three-line contract whose middle line separates its
  columns with spaces instead of TABs (the shape an orchestrator writing the
  file will produce): the only criterion that would have gone RED vanished,
  `results.json` said green, and the stop-gate allowed the stop.
  `run-contract.sh` now classifies each line once — blank, whitespace-only and
  `#comment` lines (a leading indent tolerated) are skipped as before, anything
  else missing a column is recorded as malformed, forces the ledger red, is
  named by line number on stderr and in a new `malformed_lines` field, and
  suppresses evidence pruning, because a partial parse has an incomplete id set
  and pruning would delete a still-valid log on the very run reporting the
  fault. `arm-contract.sh` warns about the same lines at arm time, which is the
  only moment `criteria.tsv` is still writable.
- **The stop-gate allowed a stop when `criteria.tsv` existed but its runner did
  not.** The dispatch tested `[ -f criteria.tsv ] && [ -f run-contract.sh ]`,
  then the legacy `verify.sh` path, then "allowing stop" — so a missing runner
  landed in the contract-less branch, which exists for an unrelated reason
  (`arm-contract.sh` arms legacy loops that have no `criteria.tsv`, and blocking
  those would deadlock them). With a RED contract armed, the gate allowed the
  stop and explained itself with "no criteria.tsv or verify.sh" about a file
  sitting right in front of it: armed in appearance, enforcing nothing.
  Reachable with no adversary — an interrupted `/plugin update` leaves `hooks/`
  present and `skills/` not yet, and the README documents registering the hooks
  manually in `settings.json`, where a `<plugin-root>` resolving outside the
  plugin tree produces exactly this. A contract that exists and cannot be
  executed is UNVERIFIED, not absent: it now blocks, names the path it looked
  for, and says how to recover. Handled after the block counter is read, so
  `MAX_BLOCKS` still bounds it and a broken install cannot deadlock a session
  either. The genuinely contract-less case is untouched and still allows.
- **An unrecordable result failed closed only by coincidence.** Neither output
  write was checked. An unwritable `.loop/` made the `{ … } > "$TMP"` group's
  redirect fail, so the criteria loop never executed and its counters were never
  assigned — the script exited non-zero three lines later purely because
  `set -u` tripped over an unbound variable, printing bash internals where a
  cause belonged. Hoisting those initialisations out of the group command, an
  ordinary cleanup, would have turned a full disk into a false ALL GREEN. An
  unusable evidence directory was quieter still: every criterion's log redirect
  failed, so PASSING checks reported as failing with nothing saying why. Both
  now fail closed deliberately with exit 73 (EX_CANTCREAT, matching the sysexits
  codes these scripts already speak) and a message naming what could not be
  written, which the stop-gate feeds back in band as the block reason.
- **`install-timer.sh` accepted a polish scope that is not in the repo.** The
  installer already refuses a bad `--time`, a non-git repo, a missing runner, an
  unresolvable `claude` binary, and any path carrying whitespace or a percent
  sign — each because the unit would otherwise enable cleanly and break at first
  trigger, with the error visible only in the journal at 03:00. A scope that
  does not exist is the same family and was the one case left unchecked:
  verified before the fix, `install-timer.sh polish <repo> lib/` into a repo with
  no `lib/` wrote and enabled the unit, exit 0, after which every nightly run
  reviews a path that is not there, finds nothing, and reports success.
  `unattended-polish.sh`'s own header records this outcome having happened via a
  flag mistaken for the scope; it rejects that shape already, but a typo'd or
  since-moved directory still reached the unit file. The check is glob-tolerant,
  since `/polish` takes scope paths and `src/*.ts` is legitimate input that
  `test -e` would never match literally.

### Changed
- Docs follow the code: `CLAUDE.md`'s description of what the stop-gate fails
  closed on now lists the partly-parsed and missing-runner cases alongside the
  vacuous and hash-lock ones, with the rule they share — a contract the runner
  could not fully parse or execute is never reported green. The README states
  that `criteria.tsv` columns are TAB-separated and what happens when they are
  not, and that a polish scope is checked at install time.
- `.converge/` (convergence-round bookkeeping) is gitignored, for the same
  reason `.loop/` is: both loops and both unattended drivers refuse to run on a
  dirty tree, so notes living beside the source must not register as an
  untracked change.

## 0.11.0 — 2026-09-19

An end-to-end QA pass driven as a real user (drive the loop, not read the code):
five rounds over the `/autoloop` mechanism, the dogfood sync, the unattended
runners, the systemd timer pair, and the update notifier. Six defects, four of
them in guards that failed quietly, plus the family invariant those four kept
violating. Test suite 320 → 358 assertions.

**Live-install smoke** (RELEASING.md §1): PASS on Claude Code 2.1.278, against a
genuine `claude plugin marketplace add sdsrss/loop_eng` + `install` of 0.11.0
into an isolated `CLAUDE_CONFIG_DIR`. All five checks machine-verified, not
model-reported: the plugin resolved to `plugins/cache/loop-eng/loop-eng/0.11.0/`;
`arm-contract` printed `armed from <that cache path>`; an instrumented
`evidence-gate.sh` logged `DENY-FIRED tool=Write file=.loop/evidence/smoke.log
root=<real cache path>` and the file did not land under
`--permission-mode bypassPermissions` (so hooks.json auto-loaded AND
`CLAUDE_PLUGIN_ROOT` reached the hook process — no placeholder); the stop-gate
left `.loop/gate-count = 3` with a `generated_by: run-contract.sh` ledger; and
`/loop-eng:autoloop` reached `all_green: true` with `.loop/active` self-cleared,
which is only reachable if `${CLAUDE_PLUGIN_ROOT}` expanded inside the command
markdown.

**Upgrade note**: mostly additive — after updating run `/reload-plugins` or
start a fresh session; the hook-side changes only take effect once the plugin
cache is on 0.11.0. **One behavior change can break an existing schedule**:
`unattended-polish.sh` now rejects malformed arguments with exit 64 instead of
silently degrading to report-only, so a cron line like
`unattended-polish.sh /repo --auto-fix` (scope omitted) that appeared to work
will now fail loudly. That is the fix — it was never doing what it looked like —
but check your crontab and any hand-written systemd units before updating.
Units written by `install-timer.sh` are unaffected. Revert path: pin v0.10.0.

### Fixed
- **The stop-gate's block reason was empty on the primary path.** `run-contract.sh`
  writes every detail to `.loop/results.json` + `.loop/evidence/`, and nothing to
  its own stdout/stderr — so the stop-gate's "Output tail:" had nothing under it,
  and the one in-band signal a blocked model gets said the contract was
  unsatisfied without saying which criterion failed. `run-contract.sh` now prints
  a failure summary to stderr (`N of M criteria FAILED`, then per red criterion
  its id, description, exit code and the last 3 lines of its evidence log, each
  cut to 200 columns); a vacuous contract likewise explains itself instead of
  failing closed in silence. Green runs stay silent. The gate's feedback window
  grew 15 → 40 lines to fit the summary, and evidence drops to one line per
  criterion past the eighth failure so the worst case stays inside it
  (1 + 4·min(N,8) + 2·max(N−8,0) lines: 37 at N=10, where 3-lines-each gave 41
  and cost the header). Ledger and evidence files are unchanged — this adds a
  channel, it does not move the machine record.
- **`unattended-polish.sh` let its dirty-tree guard fail OPEN outside a git repo.**
  `git status --porcelain` in a non-repo writes its fatal to stderr and leaves
  stdout empty, so `grep -vq` reported "not dirty" and the run proceeded — an
  unattended `--permission-mode bypassPermissions` session editing a directory
  with no version control, where nothing is attributable and nothing can be
  reverted, which is precisely what the guard exists to prevent. Both unattended
  runners now establish a git work tree up front and refuse otherwise;
  `unattended-autoloop.sh` previously reached this point only to die on
  `git rev-parse` under `set -e` (exit 128 plus raw git noise).
- **`LOOP_ENG_GATE_TIMEOUT=0` silently disabled the stop-gate's fail-closed
  budget.** `0` passes an all-digits check, but GNU `timeout 0` means *no* limit,
  so the guard that blocks deliberately before the platform kills an overrunning
  Stop hook (a killed Stop hook does not reliably block, which would let an
  UNVERIFIED contract stop) was simply absent. Now warns and falls back to 100 —
  the same `10#`-guarded treatment `arm-contract.sh` and both unattended runners
  already gave their own budgets. The gate was the one call site that lacked it.
- **`unattended-polish.sh` accepted malformed arguments as a clean run.**
  `unattended-polish.sh <repo> --auto-fix` (scope omitted) put the flag in the
  scope slot: report-only, exit 0, reviewing a scope that does not exist — a
  nightly timer would look healthy for weeks. `--auto-fixx` was ignored just as
  quietly. Malformed arguments are now a usage error (exit 64, EX_USAGE),
  naming what was wrong; `install-timer.sh` already refused unknown options this
  way. The installer-generated `ExecStart` shapes are unaffected.
- **`arm-contract.sh` handled `LOOP_ENG_ARM_REDCHECK_TIMEOUT=0` correctly but
  silently**, and was the only one of the plugin's four budget knobs with no
  assertion pinning it — which is how the very same gap survived in
  `stop-gate.sh`. It now warns like its three siblings, and each of the four has
  a test asserting that 0 warns and a valid value does not. The invariant, in
  one line: for every budget knob, `0` is a config error, never "no budget"
  (GNU `timeout 0` disables the timeout).
- **`install-timer.sh --time` with no value exited 1 with an empty stderr.**
  `shift 2` on a single remaining argument fails, and under `set -e` that killed
  the script before the HH:MM validation could speak. The value is now checked
  before the shift.

### Changed
- README: the evidence-gate's Bash matching rule is described as implemented —
  a write verb (`>`/`>>`, `tee`, `mv`, `cp`, `sed -i`, `truncate`, `rm`) ahead of
  a protected path in the same segment. Merely naming a protected path does not
  trip it, so the documented example of a false positive (a commit message
  quoting the pattern) was not one; `grep passes .loop/results.json` and
  `git commit -m "document .loop/results.json"` both pass today.
- README: the safety table said checker/reviewer/verifier agents "have no write
  tools". They have no Write/Edit tools and keep Bash — they must run the checks
  — so it is a whitelist, not a sandbox. Stated that way now, matching how the
  evidence-gate's own Bash residual is already documented.
- README: the unattended runners' refusal list now names non-git targets and
  malformed arguments.
- CLAUDE.md documents a local way to check the bash 3.2 floor
  (`docker run --rm bash:3.2` — a real 3.2.57, the release stock macOS ships)
  and bans `BASH_COMPAT=3.2` as a stand-in. `BASH_COMPAT` restores bash ≤4.2
  replacement-backslash semantics, so `json_str`'s `${s//\\/\\\\}` stops
  doubling backslashes and the TAB assertion fails against code that is correct
  on every real bash — a false positive that, acted on, breaks the ledger.
  Verified: 3.2.57 and 5.3.9 agree; only `BASH_COMPAT=3.2` differs.

## 0.10.0 — 2026-07-14

The UX batch, from a real-user sandbox audit of the install / lifecycle /
residue story, plus two robustness fixes. Driven by one /autoloop roadmap run
(5 rounds, 5/5 ALL GREEN) and two direct mechanism edits. Test suite 263 → 320
assertions.

**Upgrade note**: additive — after updating run `/reload-plugins` or start a
fresh session. Two of this release's improvements only take effect once the
plugin cache is on 0.10.0 (they run from the installed copy, not the repo): the
evidence-log pruning and the evidence-gate arrow fix. Revert path: pin v0.9.0.

### Added
- **Update-available notifier** (new `hooks/update-notify.sh`, SessionStart):
  once per 24h (cached under `${XDG_CACHE_HOME:-$HOME/.cache}/loop-eng/`, never
  `~/.claude/`) it checks the latest GitHub release and, only when the installed
  version is behind, prints a one-line "update available — run `/plugin update
  loop-eng`" notice via the SessionStart JSON envelope. A single 3s-timeout
  curl; no auto-download; fails silent and non-blocking on missing curl / no
  network / parse error / throttle. Fills the gap where a marketplace user got
  zero signal that a new version existed.
- `run-contract.sh` **prunes stale evidence logs**: `.loop/evidence/<id>.log`
  files whose id is not in the current contract are removed each run, so a repo
  that runs many loops no longer accumulates orphan evidence forever. Runs after
  the ledger is written, never deletes the current run's evidence, and never
  fires on a fail-closed run (hash mismatch / no-sha-tool → evidence preserved).

### Fixed
- `evidence-gate.sh`: a Bash command that only NAMES a guarded ledger path via a
  literal `->` arrow plus a read subshell (e.g. an echoed progress line) had the
  arrow's `>` read as a redirect verb and was spuriously denied. Arrows are now
  blanked before the match — true-positive-preserving (no real redirect contains
  `->`); the match stays deliberately conservative otherwise (the hash-lock is
  the real backstop). The deny message now names this mention-only false positive
  and its escapes.
- `uninstall-timer.sh` reaps the orphan it used to leave behind: install-timer
  pre-creates `$REPO/.loop/` for the unit's log, and uninstall now parses `$REPO`
  from the `.service` unit before deleting it and removes `.loop/cron.log` +
  `rmdir`s `.loop` — but ONLY when `.loop` holds nothing else (a live loop's
  state is never destroyed; preservation is tested).

### Docs
- README `## Safety model`: unattended write mode (`--allow-write` /
  `LOOP_ENG_ALLOW_AUTOBUILD` / `LOOP_ENG_ALLOW_AUTOFIX`) is real no-approval
  write+commit via `--permission-mode bypassPermissions` (off by default,
  guarded); `.loop/` is local state and is not auto-removed on uninstall.
- CLAUDE.md `### Packaging scope`: a git-based marketplace install ships the
  **full git tree** (tests included, ~40KB) — Claude Code has no manifest
  exclude field or `.claudeignore`; documented as acceptable rather than
  contorting the repo.
- `skills/loop-eng/SKILL.md`: "What the mechanism does and does NOT guarantee" —
  the arm-time red-check catches vacuous (already-green) criteria, not weak
  (red-but-tests-the-wrong-thing) ones; machine-written evidence covers criteria
  pass/fail, not the orchestrator's surrounding prose.

## 0.9.0 — 2026-07-14

The audit-closure batch: every remaining finding from
`docs/audit-report-v0.7.0-2026-07-14.md` (test batch, docs batch, low-severity
tail) plus three optimizations distilled from the same day's live dogfood
loops. Driven end-to-end by three /autoloop roadmap runs on the released 0.8.0
enforcement — 10 rounds, 10/10 ALL GREEN, zero rework rounds.

**Upgrade note**: no action required — behavior changes are additive
(broader provider-limit detection; install-time refusals for values systemd
would corrupt; a truthful sync-local warning). After updating run
`/reload-plugins` or start a fresh session. Revert path: pin v0.8.0.
Live-install smoke: hooks/ untouched this release; the evidence-gate leg
passed live on 0.8.0 the same day (see 0.8.0 note).

### Added
- Test coverage +45 assertions (218 → 263), closing every audit test gap:
  provider-limit retry/exit-75 path of the autoloop driver (was ZERO-covered),
  stop-gate armed-without-contract allow-stop, the no-SHA-256-tool fail-closed
  branches of arm/run-contract (PATH-stripping fixture), a real
  LOOP_ENG_LOOP_DIR test (the scripts' "suite sandboxes with it" comment is
  now true), uninstall-timer autoloop-mode symmetry + bad-mode refusal,
  hooks-json content checks iterating EVERY hook block (12 → 19, no more
  latent-blind `[0]` indexing), percent-refusal and quota-phrasing cases.
- `install-timer.sh`: a literal `%` in any of the four systemd-injected
  values (repo dir, runner path, claude path, polish scope) is refused at
  install time — systemd expands `%` as a unit specifier, the same
  "enables cleanly, breaks at first trigger" class as the whitespace guards.

### Changed
- Both unattended drivers detect more provider-limit phrasings:
  `quota` / `overloaded` / `too many requests` join `usage limit` /
  `rate limit(ed)` (identical pattern in both scripts; still only consulted
  when a session exits non-zero). A "quota exceeded" session now takes the
  wait-and-retry / exit-75 path instead of the generic breaker path.
- `scripts/sync-local.sh`: the dogfood parity check no longer greps
  `.claude/settings.json` for hook filenames (a permanent false positive —
  hooks load via the installed plugin's hooks.json, never project settings).
  It now compares the highest installed plugin-cache version against the
  repo's plugin.json and warns when live enforcement lags the repo
  (`LOOP_ENG_PLUGIN_CACHE_DIR` override for tests; silent on fresh clones).
- `commands/autoloop.md` protocol, from live-dogfood findings: dispatch
  builder/checker SYNCHRONOUSLY (an async dispatch burns armed stop-gate
  blocks while the orchestrator waits, and builder reports arrive duplicated
  after the loop closes); intermediate-round checkers run the contract's
  fast subset with the full sweep reserved for the final round (five
  full-sweep rounds caught nothing the subset would have missed); Step-1
  backlog lines carry the `| verify:` suffix like roadmap triage; the
  dogfood-fallback note is stated once in Step 0 (file net smaller).

### Docs
- README: "Environment variables" reference table covering all 11
  `LOOP_ENG_*` knobs (LOOP_DIR clearly marked TEST-ONLY) and a note that
  marketplace installs may resolve commands namespace-prefixed
  (`/loop-eng:autoloop`).
- RELEASING.md: the live-smoke cache locator picks the highest cached
  version via `sort -V` and echoes the resolved path (a `head -1` pick could
  silently smoke a stale version when multiple versions are cached).

## 0.8.0 — 2026-07-14

**Upgrade note**: `unattended-autoloop.sh` now exits **1** when it stops with
backlog items still pending (session cap / wall-clock budget / circuit
breaker) — previously every stop path exited 0. If a wrapper or monitor
treats any non-zero exit as fatal, adjust it: exit 0 = backlog drained,
1 = gave up with items pending, 75 = provider limit (unchanged). Revert
path: pin v0.7.0. Live-install smoke (RELEASING.md §1): evidence-gate leg
PASSED live post-ship 2026-07-14 — after `/plugin update` the user-scope
cache is 0.8.0 and a probe Write to `.loop/results.json` was DENIED with the
deny text naming the runner under the real 0.8.0 cache path (hooks.json
auto-load + `${CLAUDE_PLUGIN_ROOT}` both confirmed in a live session). The
stop-gate-block and command-expansion legs remain covered by the 0.5.0 live
run of 2026-07-14 (no hooks/ change since).

Audit-driven batch from `docs/audit-report-v0.7.0-2026-07-14.md` (batches 1-2:
same-day items + small-fix batch).

### Changed
- **`unattended-autoloop.sh` exit code now reflects the remaining backlog**
  (user-visible behavior change — the next release MUST be a MINOR bump):
  the driver exits **1** when it stops with unchecked backlog items left
  (session cap / wall-clock budget / circuit breaker), so a systemd unit or
  any exit-code monitor can tell "converged" from "gave up". Exit 0 now means
  the backlog was drained; the provider-limit stop keeps exit 75. Revert
  path: pin v0.7.0. (audit A2)

### Fixed
- `run-contract.sh`: two criterion ids that sanitize to the same evidence
  filename (`a/b` and `a:b` → `a_b.log`) no longer overwrite each other's
  evidence — repeats get a numeric suffix (`a_b.2.log`) and results.json
  cites the real per-criterion path. Pass/fail was never affected; the
  evidence attribution was. (audit A6)
- `arm-contract.sh` pre-arm red-check: criterion commands now run with stdin
  from `/dev/null`, matching run-contract.sh — a stdin-reading criterion no
  longer swallows the remaining criteria lines (which silently skipped their
  already-green warnings). (audit A12a)
- `install-timer.sh`: the polish scope argument is whitespace-validated like
  every other value injected into the unit's unquoted `ExecStart` — a scope
  like `"legacy code/"` previously enabled cleanly and split into a wrong
  scope plus a stray flag argument at first trigger. (audit A7)

### Docs
- `commands/autoloop.md` roadmap mode: stop rules 3 (same failure) and 5 (no
  progress) explicitly reset at each item boundary — item N+1's first
  expected-red round is not "no progress" after item N's ALL GREEN. (audit A3)
- `agents/loop-builder.md`: new "when the fix request is a /polish finding"
  section carrying the red→green and zero-test-modification disciplines in
  the builder's OWN prompt (previously only polish.md — a file the builder
  subagent never sees — stated them); polish.md's dispatch step now passes
  the finding's category. (audit A4)
- `arm-contract.sh` red-check comment no longer claims "read-only": criterion
  commands are silenced, not sandboxed, and run again on every stop attempt.
  SKILL.md's contract-quality rules gain rule 4: criteria must be idempotent
  verify-only commands. (audit A12b)
- `CLAUDE.md` is now tracked in git (was gitignored — invisible to a fresh
  clone) and refreshed: stale "No CI" claim replaced with the real CI +
  RELEASING.md pointer; blanket `bash >= 4.4` floor split into the accurate
  two floors (hooks 3.2, unattended drivers 4.4); dual-source section now
  names the plugin-cache third copy that actually enforces in live sessions
  and its `/plugin update` lag. (audit A5, A1)

## 0.7.0 — 2026-07-14

### Added
- `arm-contract.sh` provenance line: after arming, it prints the path the script
  was invoked as (`armed from <path>`). In a dogfood run the loop arms from the
  installed plugin CACHE, which can lag the repo — repo-side script edits are not
  in effect until `/plugin update`. Surfacing the armed-from path makes that
  cache-vs-repo divergence visible instead of silent (it bit a live pilot: a
  stale cached red-check ran with no warning). Advisory, bash 3.2. (pilot retro)

### Changed
- `commands/autoloop.md`: new "Cost management (per-round model tiering)"
  section — the dominant token cost on a small task is the fixed per-round
  builder+checker overhead, so a genuinely trivial round MAY dispatch the builder
  at a cheaper model tier, with the hard invariant that the checker's tier stays
  >= the builder's (never let a weaker model certify a stronger one's work) and
  never downgrade on a mechanism-layer round. (pilot retro — token efficiency)
- `agents/loop-checker.md`: proof-line discipline — a green check's proof must be
  the exact figure/line the command printed (`test: 12 passed, 0 failed`), not a
  bare restated "passed"; added a matching red line. Raises the evidence quality
  of ALL GREEN reports. (pilot retro — work quality)
- Prompt audit batch (5 gaps found by a line-by-line five-axis review, each
  validated in a live sandbox simulation with real subagent dispatches):
  - `agents/loop-checker.md` "Round scope": the roadmap-mode rule (judge only the
    current round's item; pending items' criteria are EXPECTED-RED, a ticked item
    going red IS a regression) now lives in the checker's own prompt too — the
    contract was one-sided, only autoloop.md (orchestrator) knew it.
  - `commands/polish.md`: cost note in Phase 3 — low-severity single-file fixes
    MAY use a cheaper builder tier; reviewer/verifier/checker are judgment tiers
    and are never downgraded (mirrors /autoloop's Cost management).
  - `agents/loop-reviewer.md`: findings cap — at most the ~10 strongest per
    round + `MORE BEYOND CAP: <n>`; every listed finding costs one verifier
    dispatch, and later macro rounds pick up the remainder (bounded token cost,
    no finding lost).
  - `commands/polish.md`: "autoloop's stop rules apply" was a dangling
    cross-reference (the polish orchestrator never loads autoloop.md) — now
    self-contained ("regression protocol").
  - `commands/autoloop.md`: the ALL-GREEN ledger-refresh step now carries the
    same dogfood fallback path as the arm step (`${CLAUDE_PLUGIN_ROOT}` is
    undefined in this plugin's own repo).

## 0.6.0 — 2026-07-14

### Added
- `/autoloop` roadmap input: pointing the command at a prioritized roadmap /
  checklist document (instead of a single task) now runs a protocolized
  TRIAGE step — items are processed in document order (priority order is the
  document's own), each classified loopable (→ backlog line carrying its
  verify command) / too-big (→ split into loopable sub-items in place) /
  not-loopable (→ `.loop/state.md` "Deferred (not loopable)" with a one-line
  reason). The backlog then runs under the unchanged loop rules (one item per
  round, 5-round cap; overflow stays unchecked for a re-invoke or the
  unattended driver), and the wrap-up ends with a Done / Deferred / Remaining
  ledger. Prompt-layer only — no hook or script changes; the contract layer
  remains the safety net for triage mistakes (an unverifiable criterion warns
  at arm and can never go green by claim).
- `arm-contract.sh` pre-arm red-check: after pinning the hash-lock and before
  dropping `.loop/active`, the criteria are run once and any criterion already
  GREEN at arm time is warned about (stderr, advisory, non-gating). A check that
  passes before any work is done — like a test that never failed — may be
  vacuously satisfied and prove nothing. The loop still pins, still arms, still
  exits 0; the warning only surfaces the untrustworthy criterion so the author
  can tighten it. The red-check is BOUNDED: each criterion runs under a
  per-criterion `timeout` (default 10s, overridable via
  `LOOP_ENG_ARM_REDCHECK_TIMEOUT`) so a slow suite criterion no longer turns
  arming into a minutes-long run; a timeout counts as unknown (NOT a false
  already-green warning — a timeout is not green); and `LOOP_ENG_ARM_REDCHECK=0`
  disables the check entirely with ZERO criterion execution. Portable bash 3.2.
  (pilot retro)

### Changed
- `hooks/evidence-gate.sh`: the armed deny for a single Bash command that
  removes both `.loop/active` and the `.loop/criteria.sha256` hash-lock now
  advises the two-call wrap-up split — remove `.loop/active` first (which
  disarms), then the hash-lock in a second call. The gate scans the whole
  command string while the marker still exists, so the one-command removal is a
  legitimate step the model would otherwise waste a deny round-trip on; the
  message now names the fix instead of just blocking. (pilot retro)
- `commands/autoloop.md` protocol: on an ALL-GREEN outcome the orchestrator no
  longer manually disarms — it ends the turn and lets the stop-gate self-clear
  on the real stop attempt; the two-command manual disarm is now scoped to
  ESCALATION stops only. Roadmap-mode: the per-round checker judges only the
  current round's item — not-yet-built global criteria are expected-red, not
  that round's failure. Triage: trivial single-file micro-items MAY share one
  round, still one commit per item for traceability. (pilot retro)

### Docs
- README trust-boundary notes: a project-settings hook registration plus a
  global plugin install double-fires the hooks; the backlog-ticked criterion
  reads an orchestrator-writable file, so "tick a box only after the checker
  reports ALL GREEN" is a red line, not a mechanism; on interrupt-resume,
  reconcile `git log` against the backlog ticks before continuing. (pilot retro)
- README gate-scope note: the evidence-gate matches Bash commands by string, so
  a command that merely NAMES a guarded path (a commit-message body, a test
  command pointing at a sandbox) is denied too — a conservative, declared
  false positive of the best-effort locator; the way around is to reword the
  command or use the documented escape hatch. (round-3 pilot retro)
- `skills/loop-eng/SKILL.md` "Contract quality caps loop quality" section:
  three spec-authoring rules distilled from the live pilots — every target
  criterion must be RED before arming (a pre-green criterion is vacuous), specs
  must carry non-functional requirements (an omitted perf/timeout constraint is
  a regression faithfully implemented), and "must not happen" belongs in a
  checkable negative assertion. The loop's output quality is capped by the
  contract's spec quality. (round-3 pilot retro)

## 0.5.0 — 2026-07-14

The full audit-driven roadmap batch (21/21 items from
`docs/optimization-roadmap-2026-07-14.md`, derived from
`docs/audit-report-v0.4.1-2026-07-14.md`): mechanism fixes, /autoloop prompt
revisions, CI on ubuntu+macOS, a live marketplace-install verification, and a
release checklist (`RELEASING.md`). No breaking changes.

**Upgrade note**: no action required — no default behavior changes for
existing loops. After updating the plugin, run `/reload-plugins` (or start a
fresh session): an in-place install/update is INERT in the running session
(commands unresolved AND hooks not firing — verified live 2026-07-14). Revert
path: reinstall v0.4.1.

### Verified (closes audit H2/N1 — the enforcement layer now has live mileage)
- Live-install smoke (`RELEASING.md` §1) PASSED 2026-07-14 against
  main @ c1c6aed (plugin cache labeled 0.4.1). Findings, all expected-or-fixed:
  - Hooks/commands require `/reload-plugins` (or a fresh session): in the
    pre-reload session the install is inert — a hand-written
    `.loop/results.json` went through and no command resolved.
  - Post-reload, evidence-gate DENIED the same write, naming the real
    plugin-cache runner path (P5 fix observed live).
  - stop-gate blocked stops 1/3 and 2/3 on a red contract and machine-rewrote
    the hand-written ledger to `all_green: false` on the first stop attempt.
  - `/loop-eng:autoloop` (commands are namespace-prefixed) ran a full loop:
    legitimate close-out of the stale red contract via stop rule 6 + ordered
    two-command disarm (P1 observed live), dirty-tree precondition + baseline
    ref (P2 observed live), arm via expanded `${CLAUDE_PLUGIN_ROOT}`,
    builder/checker round, ALL GREEN with machine ledger, free stop after.

### Fixed
- `unattended-autoloop.sh`: each `claude -p` session now runs under
  `timeout -k 30 <remaining-wall-clock-budget>` (with the stop-gate's
  timeout/gtimeout fallback and a loud warning when neither exists). Previously
  `LOOP_ENG_MAX_MINUTES` was only checked BETWEEN sessions, so a single hung
  session (network stall, wedged tool) blocked the driver indefinitely — under
  a systemd oneshot unit, potentially for days. A timed-out session (exit 124)
  is named in the driver log and counts toward the no-progress breaker.
  (audit N2)
- `install-timer.sh`: the claude CLI is now resolved to an absolute path at
  INSTALL time (honoring `LOOP_ENG_CLAUDE_BIN`) and pinned into the unit via
  `Environment=LOOP_ENG_CLAUDE_BIN=<abs>`; an unresolvable claude dies at
  install. Previously the unit's hardcoded `PATH` could simply not contain
  claude (nvm / custom npm prefix), so the runner failed with exit 127 at first
  trigger with the error only in cron.log — the "installed but silently never
  runs" trap this script exists to kill. A claude path containing whitespace is
  refused like the repo/plugin paths. (audit N3)
- `unattended-autoloop.sh`: a backlog file deleted mid-run made `count_pending`
  return an empty string, which silently skipped the "backlog empty" stop (the
  `[ "" -eq 0 ]` error is swallowed by `if`) and kept launching sessions against
  a missing backlog; it now counts as 0 pending and the driver stops cleanly.
  (audit N4)
- `unattended-{polish,autoloop}.sh`: `LOOP_ENG_MAX_MINUTES=0` passed the digit
  check but `timeout 0m` DISABLES the timeout (GNU semantics) — the opposite of
  a budget knob's lowest value; 0 now warns and falls back to the default.
  (audit L7)
- `stop-gate.sh`: the block-ceiling message now includes the manual disarm
  command (`rm .loop/active`) — reaching the ceiling usually means the
  orchestrator failed to disarm, and without it every later stop attempt in the
  session eats another 3 blocks. (audit M5)

### Changed (prompt revisions, /autoloop orchestration text)
- `commands/autoloop.md` Wrap-up: disarming is now TWO ordered Bash commands
  (`rm -f .loop/active .loop/gate-count`, then `rm -f .loop/criteria.sha256`).
  The previous "remove all three" instruction, executed as one command while
  armed, was denied by the plugin's own evidence-gate (sandbox-proven exit 2)
  with a misleading "weakening a check" message — the model wasted a deny
  round-trip on a legitimate step. (audit P1)
- `commands/autoloop.md` Step 0: added preconditions — a clean tree (dirty
  trees conflate the user's uncommitted work into the final diff) and a
  recorded baseline ref (`git rev-parse HEAD` into `.loop/state.md`); Step 3's
  final diff now cites `git diff <baseline>..HEAD` instead of the unrecorded
  "pre-loop commit". Aligns /autoloop with /polish Phase 0. (audit P2)
- `commands/autoloop.md` arming: when dogfooding this repo via `.claude/`
  (`${CLAUDE_PLUGIN_ROOT}` undefined), use the local
  `.claude/skills/loop-eng/scripts/arm-contract.sh` rather than silently
  falling back to `touch .loop/active` — the fallback loses the hash-lock, so
  dogfood loops were running a degraded contract without noticing. (audit P3)
- `hooks/evidence-gate.sh`: the deny message now names the run-contract.sh
  runner by `$CLAUDE_PLUGIN_ROOT/...` (real absolute path when the platform
  provides it, an explicit placeholder otherwise) instead of a
  project-relative `skills/...` path that does not exist in a user project
  under a marketplace install. (audit P5)

### Added
- CI (`.github/workflows/test.yml`): `bash tests/run-all.sh` on
  ubuntu-latest + macos-latest for every push to main / PR. The project's own
  philosophy applied to itself — a push's "done" is now a machine-verified
  fact, not a human remembering to run the suite. macOS installs brew bash
  (stock 3.2 is too old for the unattended drivers) + shellcheck. (audit H3)

### Docs
- README scope notes (stop-gate section): one loop per repo at a time
  (concurrent arming overwrites the hash-lock → tamper fail-closed) (audit
  M6); the stop-gate guards /autoloop only — /polish has no mechanism-layer
  completion gate (also noted in SKILL.md); `LOOP_ENG_LOOP_DIR` declared
  test-only, with matching header comments in arm-contract.sh /
  run-contract.sh — the hooks are fixed to `.loop/`, so a custom dir silently
  disarms them (audit M3); ledger backup via `cat > dest` (the gate's Bash
  pattern can't tell copy direction) (audit L1).
- README safety-model table: new row naming test/build output as untrusted
  text — checker reports are forwarded verbatim by design, and
  prompt-injection riding in tool output is a residual covered by red lines +
  human diff review.
- README unattended runs: systemd timer pair promoted to the preferred
  scheduling path; cron demoted to the no-systemd fallback (audit N5).
- Test stub portability: the autoloop stub's progress filename is now
  `$$`-unique instead of `date +%s%N` (BSD date prints a literal N — a
  same-second collision would make an empty commit and a flaky breaker count
  on macOS CI).

### Dogfood
- `.claude/settings.json` (untracked): registered the evidence-gate PreToolUse
  hook and aligned hook timeouts with `hooks/hooks.json` (Stop 120s — the
  previous unset timeout defaulted below the gate's 100s internal budget;
  PreToolUse 30s). The audit found the evidence-gate had ZERO live mileage:
  never marketplace-installed, and the dogfood settings registered only the
  Stop hook. (audit N1)
- `scripts/sync-local.sh`: after syncing, warns if `.claude/settings.json`
  does not register stop-gate.sh or evidence-gate.sh — synced-but-unregistered
  hooks mean the dogfood repo exercises only part of the enforcement layer.

### Tests
- New `tests/test-hooks-json.sh` (+12): hooks.json must parse and carry the
  structural contract — Stop → stop-gate.sh via CLAUDE_PLUGIN_ROOT with a
  timeout above the gate's internal budget (cross-checked against the
  LOOP_ENG_GATE_TIMEOUT default in stop-gate.sh); PreToolUse → evidence-gate.sh
  covering Write/Edit/MultiEdit/NotebookEdit/Bash. One slipped comma in this
  file silently disables the whole enforcement layer. (audit B5-1)
- New `tests/test-sync-local.sh` (+10): sync fidelity against a sandboxed copy
  of the plugin tree — byte-identical commands/agents/hooks/skills, executable
  bits preserved, settings.json untouched, parity warning fires exactly when a
  hook is unregistered, drift is detectable and a re-sync clears it. The sync
  had a silent-omission precedent (evidence-gate.sh, pre-v0.2.2) and no test.
  (audit B5-2)
- CI portability fixes from the first macOS run (5 red assertions, all
  test-side): `mk_sandbox_repo` now canonicalizes the sandbox path (macOS
  $TMPDIR lives under /var → /private/var, so installer-canonicalized paths
  never matched raw mktemp strings); the autoloop progress stub marks backlog
  items with awk instead of GNU sed's `0,/re/` first-match address (BSD sed
  lacks it — the stub never committed and the happy path flaked into the
  breaker); macOS CI installs coreutils so the stop-gate timeout tests run
  instead of SKIPping.
- `commands/polish.md`: documented the dedup-key tradeoff (audit B5-3/P4) —
  `file:line|summary` keeps line drift as accepted verifier-cost noise;
  line-less keys were rejected because they can silently drop one of two
  same-summary findings in a file.
- Suite 143 → 183 assertions: `test-unattended-autoloop` +10 (fake-timeout
  wiring, expire→breaker, backlog-deleted stop, MAX_MINUTES=0),
  `test-install-timer` +3 (pinned claude Environment line, unresolvable-claude
  refusal ×2), `test-unattended-polish` +2 (MAX_MINUTES=0),
  `test-stop-gate` +1 (ceiling disarm hint), `test-evidence-gate` +2 (deny
  message resolves the runner via CLAUDE_PLUGIN_ROOT / placeholder without it).
  install-timer tests now inject a stub claude (`LOOP_ENG_CLAUDE_BIN`) so they
  stay hermetic on claude-less CI.

## 0.4.1 — 2026-07-11

Audit-driven fix batch (source: `docs/audit-report-v0.4.0-2026-07-11.md`). All
are bugfixes / hardening restoring intended behavior; no breaking changes.

### Fixed
- `install-timer.sh`: resolved the unattended runner from the target repo
  (`$REPO/skills/loop-eng/scripts/unattended-<mode>.sh`), so scheduling only
  worked when the target repo WAS the plugin repo — a marketplace-installed
  plugin has its runners in the plugin cache, not in the user's project, so
  `install-timer` failed with "runner not found" against any real target. It now
  resolves the runner from its OWN directory (`dirname "$0"`); the `<repo>` arg
  is purely the project to schedule against. (audit H1)
- `install-timer.sh`: a repo (or plugin) path containing whitespace produced a
  systemd unit that passed `systemctl enable` but failed at first trigger
  (`ExecStart` is whitespace-delimited and injected unquoted; the error only
  reached the journal). It now refuses such a path at install time with a named
  reason, instead of writing a unit that silently never runs. (audit M1)
- `install-timer.sh`: the unit's `StandardOutput/Error` append to
  `$REPO/.loop/cron.log`, which systemd opens before `ExecStart` — but the
  runner's own `mkdir -p .loop` runs inside `ExecStart`, too late for the first
  run's log. Install now pre-creates `$REPO/.loop`. (audit M2)
- `evidence-gate.sh`: the Write/Edit lock on `.loop/criteria.tsv` (and its
  `.sha256`) required the file to already exist (`[ -f "$FILE" ]`), so while a
  legacy `verify.sh` loop was armed a model could CREATE a fresh trivial
  `criteria.tsv` and hijack the stop-gate (which prefers `criteria.tsv` over
  `verify.sh`). The lock now denies the create as well as the overwrite while
  armed. The Bash path already covered this; only the tool path had the gap.
  (audit M4)
- `evidence-gate.sh`: `NotebookEdit` carries its target in `notebook_path`, not
  `file_path`, so the gate read an empty path and let NotebookEdit writes to the
  ledger through unchecked. The parser (jq and python3 branches) now falls back
  to `notebook_path`. (audit L2)

### Tests
- Suite 135 → 143 assertions: `test-install-timer` +3 (plugin-resolved runner,
  `.loop` pre-creation, whitespace refusal), `test-evidence-gate` +5 (armed
  create-deny for `criteria.tsv` abs+rel, not-armed create-allow, NotebookEdit
  deny + allow).

## 0.4.0 — 2026-07-11

### Added
- `install-timer.sh` / `uninstall-timer.sh`: a symmetric pair to schedule the
  unattended polish/autoloop runners as a `systemd --user` timer, instead of
  hand-dropping unit files (which get forgotten, or left "installed but never
  enabled" so they silently never run). `install-timer.sh` writes the
  `.service` + `.timer`, resolves absolute paths, validates `--time`/repo/args,
  and `enable --now`s the timer — a failed enable exits non-zero rather than
  leaving an un-scheduled orphan. `uninstall-timer.sh` disables and removes in
  reverse order and is a benign no-op when nothing is installed. Report-only /
  no-build by default; `--allow-write` opts into the mode's write env. Honors
  `XDG_CONFIG_HOME`; `LOOP_ENG_TIMER_NO_SYSTEMCTL=1` for headless/CI. The timer
  is intentionally not `Persistent` — enabling a persistent timer after the
  day's `OnCalendar` had passed would fire an immediate catch-up run (a surprise
  mid-day execution just from installing); missed nightly runs are skipped, not
  back-filled. 21 new assertions (`tests/test-install-timer.sh`), suite
  110 → 131.

### Fixed
- `run-contract.sh`: a CRLF-authored `criteria.tsv` left the line-ending CR on
  the last (command) column, so `bash -c "true\r"` ran a command whose name
  ended in CR — "command not found" (exit 127). Every passing check reported a
  false RED and the loop could never reach ALL GREEN. Strip the trailing CR
  before execution (the JSON-escaping path already handled CR; the exec path
  did not). Direction was fail-safe (false-RED, never false-green).
- `install-timer.sh`: the "repo-dir does not exist" error printed a blank path
  because the `cd`-based canonicalization overwrote the variable before the
  error fired; it now reports the original argument the user passed.
- Regression coverage for both: suite 131 → 135 (`test-run-contract` +2 CRLF,
  `test-install-timer` +2 nonexistent-repo path).

## 0.3.0 — 2026-07-10

Descriptions-only release: changes when Claude Code auto-invokes the plugin,
not what the loops do. No user action required; to restore the old routing
behavior, reinstall v0.2.3.

### Changed
- Rewrote the LLM-visible descriptions of `/autoloop`, `/polish`, and the
  `loop-eng` skill from feature-driven (mechanism jargon) to scenario-driven:
  each now front-loads "Use when" trigger conditions with natural user phrases
  (bilingual EN/中文, e.g. "keep going until tests pass", 挂机/无人值守/打磨),
  and names its differentiator (/polish vs one-shot code review; the skill vs
  prompt-only goal trackers). Raises Claude Code's auto-invocation recall on
  genuine loop intent; no behavior change — hooks, scripts, and agents untouched.

## 0.2.3 — 2026-07-10

Three false-verdict fixes in the contract runner, found by end-to-end testing of
the real /autoloop flow. All are bugfixes restoring intended behavior — a
contract must fail closed when it verifies nothing, must never emit invalid
evidence, and must not fail a criterion for its name.

### Fixed
- `run-contract.sh`: a `criteria.tsv` with ZERO runnable criteria (empty,
  all-comment, or every line malformed) produced `all_green: true` / exit 0 — a
  false green that let the stop-gate lift on a vacuous contract, defeating the
  whole "done is a machine-verified, multi-criterion fact" guarantee. It now
  fails CLOSED (`all_green: false`, exit 1, `error` naming the vacuous contract).
  `arm-contract.sh` additionally warns at arm time so the mistake surfaces
  immediately, not at the first stop.
- `run-contract.sh`: a criterion field containing a TAB (a 4+ column line, or a
  CRLF-authored `criteria.tsv` leaving a trailing CR) emitted a raw control
  character into `results.json`, making it invalid JSON — the checker agent,
  humans, and any tooling that parses the evidence ledger would choke. `json_str`
  now escapes TAB and CR — and replaces any other residual C0 control byte with a
  space — so `results.json` is valid JSON for any field byte content, not just the
  common TAB/CRLF vectors. It is also pure-bash, so it stays portable and drops a
  per-field `sed` subprocess.
- `run-contract.sh`: a criterion whose `id` contained `/` (e.g. `lint/eslint`)
  produced a false RED — the evidence log path pointed at a non-existent nested
  dir, the redirect failed, the command never ran, and a passing criterion
  reported `passes: false`, so the loop could never go green. The id is now
  sanitized for the evidence FILENAME only (the JSON keeps the real id); this
  also blocks a `..` id from escaping `.loop/evidence/`.
- `unattended-autoloop.sh`: a non-numeric `LOOP_ENG_MAX_MINUTES` (e.g. a typo'd
  scheduler env var) crashed the driver immediately (`xyz: unbound variable` in
  `$(( ))` under `set -u`), and a non-numeric `max-sessions` arg silently
  disabled the session cap while spamming `[: integer expression expected` every
  iteration. Both numeric knobs (plus `LOOP_ENG_LIMIT_WAIT_MIN`) are now
  validated up front — an unattended entry point WARNS and falls back to the
  default rather than aborting or misbehaving on a bad value. Validated values
  are also normalized to base-10, so a leading-zero knob like `08`/`09` no longer
  crashes bash arithmetic (`$((08*60))` → "value too great for base").
- `unattended-polish.sh`: same guard for `LOOP_ENG_MAX_MINUTES`, which otherwise
  reached `timeout "${MAX_MINUTES}m"` and failed opaquely on a non-numeric value.

- `commands/autoloop.md`: on `ALL GREEN`, Step 3 told the orchestrator to cite
  `.loop/results.json (all_green: true)` as machine proof — but nothing in the
  loop refreshes that file after the fix (builder and checker run the raw verify
  commands, not `run-contract.sh`; the ledger is refreshed lazily by the Stop
  hook only at the actual stop attempt). Reading it to cite it therefore showed
  the stale pre-fix `all_green: false`, contradicting the report. Step 3 now
  runs `run-contract.sh` to refresh the ledger before citing it. (Found by an
  end-to-end `/autoloop` run: the checker itself flagged the stale ledger.)

### Docs
- `SKILL.md`: the `/autoloop` and `/polish` pointers referenced
  `.claude/commands/*.md` — the gitignored local dogfood copy, which does not
  exist in an installed plugin. Now point to the shipped `commands/*.md`.

## 0.2.2 — 2026-07-10

Closes the last open item from the 0.2.0 review: the Stop-hook timeout could
let an unverified contract stop.

### Fixed
- `stop-gate.sh`: the contract now runs under an internal budget
  (`LOOP_ENG_GATE_TIMEOUT`, default 100s) kept below the 120s Stop-hook timeout
  in `hooks.json`. Previously, a `criteria.tsv` slower than 120s would let
  Claude Code kill the hook — and a killed Stop hook does not reliably block, so
  the session could stop with the contract UNVERIFIED. If the run overruns the
  budget the gate now BLOCKS deliberately (fail closed, exit 2) with a message
  telling you to make criteria.tsv a faster subset, instead of gambling on the
  platform's kill behavior. Falls back to an unbounded run (with a warning) only
  when neither `timeout` nor `gtimeout` is available.

### Docs
- `contract.md` documents the Stop-hook time budget so authors keep the
  per-round `criteria.tsv` fast and leave the slow full suite for the final round.

## 0.2.1 — 2026-07-10

Hardening release, from a code review of 0.2.0. Two things: a silent false-green
in the contract runner is fixed, and the armed-contract lock gains a mechanical
hash-lock so weakening a check can no longer pass quietly.

### Fixed
- `run-contract.sh`: a `criteria.tsv` whose last line had no trailing newline
  silently dropped that criterion — and a dropped FAILING criterion produced a
  false `all_green: true` / exit 0, the exact outcome the gate exists to prevent.
  The read loop now processes the final unterminated line (`|| [ -n "$id" ]`),
  with a no-trailing-newline regression test.
- `run-contract.sh`: the `results.json.tmp.$$` scratch file is now trap-cleaned
  on exit (was orphaned on a mid-write kill).
- `stop-gate.sh`: the block counter is cleared when the platform block ceiling
  force-allows a stop, so a re-armed loop that inherits a stale `.loop/gate-count`
  is no longer instantly inert.

### Added
- Contract hash-lock. `arm-contract.sh` (new, replaces a bare `touch
  .loop/active`) pins `sha256(criteria.tsv)` into `.loop/criteria.sha256` at arm
  time; `run-contract.sh` re-derives that hash on every stop attempt and fails
  CLOSED (exit 77, `all_green: false`, tamper reason) if the live file no longer
  matches. Because it checks the file's *contents*, no write path can slip past —
  including Bash verbs the evidence-gate regex can't see (`python3`, `perl -i`,
  `dd`, `cd .loop && …`). `evidence-gate.sh` also locks `.loop/criteria.sha256`
  while armed; `stop-gate.sh` clears it when it lifts the gate.

### Security scope (honest)
- The Write/Edit/MultiEdit tool path to the ledger and armed contract is
  mechanically closed. The Bash path is best-effort regex PLUS the hash-lock:
  post-arm drift and single-verb weakening now fail closed and loud. A fully
  adversarial model with arbitrary Bash that rewrites BOTH `criteria.tsv` and
  `criteria.sha256` to a matching weakened pair remains out of scope — the red
  lines in the command prompts and human review of the diff cover that residual.
  Note `.loop/` is gitignored, so a weakened contract does not surface in `git diff`.
- The stop-gate runs the full `criteria.tsv` inside the 120s Stop-hook timeout;
  keep `criteria.tsv` a FAST subset (the contract already says so) — a criteria
  set slower than 120s risks the hook being killed.

## 0.2.0 — 2026-07-09

New default behavior (opt-out available): the evidence-gate PreToolUse hook
now denies model writes to `.loop/results.json`, `.loop/evidence/`, and an
armed `.loop/criteria.tsv`. Loops behave as before otherwise; if the gate
gets in your way, set `LOOP_ENG_DISABLE_EVIDENCE_GATE=1` (the deny message
says exactly this). Pre-0.2 loops using `.loop/verify.sh` keep working —
the stop-gate falls back to it when `criteria.tsv` is absent. The PreToolUse
gate is registered for Write/Edit/MultiEdit/NotebookEdit/Bash and thus runs
(as a fail-open no-op) on those tool calls in any project where the plugin's
hooks load — it only ever denies writes targeting `.loop/`-protected paths.
The contract lock is armed-scoped: `.loop/criteria.tsv` is immutable while
`.loop/active` exists and rewritable between loops.

### Added
- `run-contract.sh`: executes `.loop/criteria.tsv`, machine-writes
  `.loop/results.json` + per-criterion `.loop/evidence/<id>.log`.
- `evidence-gate.sh` (PreToolUse): completion evidence can be produced only
  by running the contract, never typed.
- `unattended-autoloop.sh`: cross-session fresh-context driver — one
  backlog item per `claude -p` session, commit-keyed circuit breaker
  (2 no-commit sessions → stop), session cap, wall-clock budget,
  usage-limit wait/retry.
- /polish impact scoping: findings classed
  `correctness|requirement|optional`; optional is reported, never auto-fixed.
- Test suite: `tests/run-all.sh` (sandboxed; bash -n + shellcheck + e2e).

### Fixed
- `unattended-polish.sh` never recorded non-zero claude exit codes
  (`set -e` killed the script before the bookkeeping line); now captured
  and passed through, with rate-limited runs exiting 75.

### Changed
- Stop gate prefers `criteria.tsv` (via `run-contract.sh`) over legacy
  `verify.sh`; documents the platform's 8-consecutive-blocks force-allow
  (loop-eng's ceiling of 3 stays under it).
- `/autoloop` writes `criteria.tsv` instead of `verify.sh`; backlog items
  use `- [ ]` checkboxes; `lessons.md` entries use one fixed format.

## 0.1.0 — 2026-07-09

Initial release: /autoloop, /polish, stop-gate, unattended polish runner.
