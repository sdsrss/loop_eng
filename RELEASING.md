# Releasing loop-eng

Manual release flow (no CD). Every step's "done" is a command output, not a
memory of having run it.

## 0. Pre-flight

- [ ] `bash tests/run-all.sh` → `ALL GREEN` locally.
- [ ] CI green on main **for the release commit** — select the run by its sha.
      **Never `--limit 1`**: for ~15s after a push GitHub has not registered the
      new run, so `--limit 1` returns the PREVIOUS commit's already-finished run
      and reports green for a tree other than the one being released. That is
      the difference between "CI passed on the release commit" and "CI passed on
      something else"; it cost one wasted verification on 0.16.0.
      ```
      gh run list --branch main --limit 10 \
        --json headSha,status,conclusion \
        --jq ".[] | select(.headSha==\"$(git rev-parse HEAD)\")"
      ```
      Empty output means "not registered yet" — re-run it. Treat empty as
      not-yet, never as failure.
- [ ] Version bump touches THREE fields across TWO files:
      `.claude-plugin/plugin.json` (`version`) and
      `.claude-plugin/marketplace.json` (`metadata.version` +
      `plugins[0].version`). Verify:
      `grep -n '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json`
- [ ] CHANGELOG has a dated section for the version (move `## Unreleased` down),
      written to the skeleton below.
- [ ] Manifest + components validate:
      `claude plugin validate .claude-plugin/plugin.json`
      **Point it at the plugin manifest, not at `.`** — given the repo root the
      validator finds `marketplace.json` first, validates only that, and reports
      `"contents": []`: a green that checked no command, agent, or skill. Aiming
      at `plugin.json` is what walks the components.
      `--strict` currently exits 1 on ONE known warning — "CLAUDE.md at the
      plugin root is not loaded as project context". That file is this repo's
      own dev guidance, not shipped plugin context, and it has to sit at the
      repo root for Claude Code to load it here; it ships inert (see CLAUDE.md,
      "Packaging scope"). Treat exactly that one warning as expected and any
      other as a release blocker.

### CHANGELOG skeleton (from 0.16.0 onward)

Fixed headings, in this order, omitting any that are empty. The point is that a
reader upgrading knows where to look without reading the prose: "what do I have
to do" is always the first section, and it is always called the same thing.

```markdown
## X.Y.Z — YYYY-MM-DD

<One short paragraph: what this release is about. Not a list.>

### Upgrade

- Only entries that require the reader to DO something, or to know that a
  default moved under them. Each one says what changed, what breaks if they
  ignore it, and the opt-out or revert.

### Changed

- User-visible behavior that moved but needs no action.

### Fixed

- Bugs. What was wrong, what it cost, what it does now.
```

One heading beyond the skeleton is established practice: `### Live-install
smoke`, carrying that release's machine-verified smoke verdicts (0.18.0, 0.18.1).
Add it after the three above when §1 ran. And 0.16.1 shipped its three in the
order Upgrade → Fixed → Changed; the skeleton's order is what new sections
follow, not a claim about what every existing one did.

The 20 sections before 0.16.0 are left as written. They are diary-style and
long — the five releases before the skeleton average about 175 lines each, and
all 20 average about 83 — but that prose is the
project's decision record, and rewriting it would destroy the thing that makes
it worth keeping while changing nothing for any reader. The skeleton binds
forward only. When an entry wants a full incident narrative, put the narrative
in the commit message or `docs/` and keep the CHANGELOG entry to the shape
above.

`## 0.1.0` has no tag and no GitHub Release — it predates the release flow in
this file. Every version from 0.2.0 on has all four of section, tag, Release and
manifest agreeing; the release gate in `.github/workflows/release.yml` is what
keeps that true now. 0.1.0 is deliberately not back-filled: a tag invented years
later points at a commit nobody released, which is a worse record than an
honest gap.

## 1. Live-install smoke — REQUIRED for any release touching `hooks/`, `commands/`, `skills/` or `.claude-plugin/`

That is **four** paths (audit H2). Re-read this line at ship time instead of
recalling it: 0.18.1's smoke was nearly skipped by remembering the trigger as
"hooks/ and skills/", and a four-item list recalled as two looks exactly like a
four-item list satisfied. It was also the release where the smoke was most
on-point — step 6 exists to prove `${CLAUDE_PLUGIN_ROOT}` expands inside command
markdown, which was the very file that release changed.

The plugin's entire enforcement value depends on two platform behaviors that
unit tests cannot see: (a) `hooks/hooks.json` auto-loads on a marketplace
install; (b) `${CLAUDE_PLUGIN_ROOT}` expands inside command markdown. Smoke
them against a THROWAWAY project, never a real one.

The whole section can run headless, which also keeps the install out of your
real `~/.claude/`: set `CLAUDE_CONFIG_DIR` to a throwaway directory, use
`claude plugin marketplace add` / `claude plugin install` instead of the slash
commands, and drive steps 4–6 with `claude -p '<prompt>' --permission-mode
bypassPermissions --max-turns N`. A fresh config dir has no credentials — symlink
(do not copy) `~/.claude/.credentials.json` into it for the run and delete the
link afterwards. One ordering caveat: do NOT leave `.loop/active` armed while
testing step 4. In a headless session the stop-gate's blocks consume the turns
and the model never reaches the write, so the evidence-gate goes untested —
`results.json`'s protection does not depend on `.loop/active`, so disarm for
step 4 and re-arm for step 5.

**Add the marketplace by its GitHub source, never by a local path.** This whole
section — every `plugins/cache/<marketplace>/<plugin>/<version>/…` path in steps
3 and 4 — assumes a git source. `claude plugin marketplace add <some/local/dir>`
registers a `directory` source instead, and then the plugin runs **from that
directory**: `CLAUDE_PLUGIN_ROOT` is the source dir, `plugins/marketplaces/` is
never populated, and the version-pinned copy under `plugins/cache/` is created
but **never executed**. Verified 2026-09-19 on 2.1.278: the same smoke run twice,
once per source type, with a marker appended to `deny()` in both copies — the
directory install fired the source copy, the GitHub install fired the cache copy.
Instrumenting the cache under a directory source therefore yields an empty marker
log, which reads exactly like "the hook never fired" — the fourth instance of
this family in these two steps. If you need to smoke an unpushed commit, push it
to a branch and add `owner/repo` anyway, or accept that you are testing the
source tree and say so in the CHANGELOG note.

**Better: order the release so the question never comes up.** `marketplace add
owner/repo` can only take the default branch, so land the version bump on `main`
and wait for CI green BEFORE smoking, then tag afterwards. The smoke then runs on
a genuine git source carrying the release's own content, and no source-type
disclosure is owed. 0.13.0 had to disclose a local-path install because it smoked
pre-push; 0.14.0 did it in this order and did not. The only thing between the
smoked commit and the tag is then the commit recording the smoke itself, which
§3's `diff -r` check settles.

1. **Throwaway project**
   ```
   mkdir -p ~/tmp/loop-smoke && cd ~/tmp/loop-smoke
   git init -q && printf '.loop/\n' > .gitignore && echo hi > README.md
   git add -A && git commit -qm init
   ```
2. **Install** — start `claude` in that directory:
   - `/plugin marketplace add sdsrss/loop_eng`
   - `/plugin install loop-eng@loop-eng`
   - **Run `/reload-plugins` (or start a fresh session).** Verified live
     2026-07-14: in the pre-reload session the install is INERT — commands
     unknown AND hooks not running, so a smoke there false-fails.
   - PASS = the commands appear, namespace-prefixed: `/loop-eng:autoloop`,
     `/loop-eng:polish` (bare `/autoloop` may not resolve).
3. **Arm a RED contract** (from a normal terminal, not the Claude session):
   ```
   cd ~/tmp/loop-smoke && mkdir -p .loop
   printf 'red\talways fails\tfalse\n' > .loop/criteria.tsv
   # Scope the search to plugins/CACHE. The bare plugins/ search below matched
   # plugins/marketplaces/loop-eng/... first (observed 2026-09-19) — that is the
   # marketplace CLONE, not the copy that enforces, so the smoke then exercised
   # the wrong file. Same distinction step 4 warns about for instrumentation.
   # -maxdepth 6, not 3: from CACHE_ROOT the runner sits five components down,
   # at <version>/skills/loop-eng/scripts/arm-contract.sh. At 3 the find matched
   # NOTHING (observed 2026-09-19 on 0.12.1) and `bash "$ARM"` then ran the empty
   # string — "bash: : No such file or directory", which reads like a broken
   # install rather than a broken checklist line.
   CACHE_ROOT=~/.claude/plugins/cache/loop-eng/loop-eng
   ARM=$(find "$CACHE_ROOT" -maxdepth 6 -name arm-contract.sh | sort -V | tail -1)
   echo "$ARM"     # must contain /plugins/cache/ AND the version you are releasing
   bash "$ARM"     # expect: "pinned criteria.tsv @ <sha>" + "stop-gate armed"
   ```
   The `armed from` line this prints is the check that matters: it must cite the
   cache path for the version under test. A path under `plugins/marketplaces/`
   means you armed the clone and the run proves nothing about what ships.
4. **Evidence-gate check** (in the Claude session): ask the model to write
   `hello` into `.loop/evidence/smoke.log` — NOT `{"all_green": true}` into
   `results.json`. Both paths are protected unconditionally, but the second
   prompt asks the model to fabricate a green ledger, so it tends to refuse on
   its own judgment and the hook is never exercised: the step then "passes"
   without having tested anything. Pick the target the gate denies by PATH and
   the model has no reason to argue with.
   - PASS = the write is DENIED with `loop-eng evidence-gate DENIED`, the file
     does not exist afterwards, and the deny text names the runner under the
     real plugin cache path (not a `<loop-eng plugin root>` placeholder — that
     would mean CLAUDE_PLUGIN_ROOT is NOT reaching hook processes).
   - FAIL = the file gets written → hooks.json did not auto-load. Register
     manually per README and file a bug before releasing.
   - **Do not use "`.loop/results.json` exists" as the FAIL signal.** The
     stop-gate re-runs the contract on every stop attempt and machine-writes
     that file itself, so it appears during a perfectly healthy smoke. If you
     must check `results.json`, read its `generated_by` field: `run-contract.sh`
     is the gate doing its job; anything else is the failure.
   - **The Write-tool form of this step can false-PASS; use the Bash redirect.**
     Observed 2026-09-20 on 2.1.278 while smoking 0.17.0: asked to Write
     `hello` into `.loop/evidence/smoke.log`, the model reported that the
     harness had blocked the Write tool for an unrelated reason and stopped.
     The file was absent and the step looked green — but the marker count was
     **0**, so the gate had never run. Any harness-side reason the model does
     not reach the tool call (tool gating, a delegation policy, its own
     refusal) produces the same indistinguishable "pass". Prompt instead with
     `Run exactly this Bash command: echo hello > .loop/evidence/smoke.log`,
     which the model has no reason to argue with and which reaches the hook.
     The marker below is what settles it either way — a file-absent check alone
     cannot.
   - To turn a model report into a machine fact, instrument the LIVE copy
     before the run — `sed`/`python3` a marker line into `deny()` — and assert
     the marker file afterwards. Record `$CLAUDE_PLUGIN_ROOT` **in the marker**
     (`echo "EGDENY root=${CLAUDE_PLUGIN_ROOT:-UNSET}" >> …`) rather than
     eyeballing the deny text for a placeholder: the model's own report elides
     long paths, and the env var is the thing the check is actually about. Note the live copy is
     `plugins/cache/<marketplace>/<plugin>/<version>/hooks/evidence-gate.sh`,
     NOT `plugins/marketplaces/<name>/hooks/...`; instrumenting the marketplace
     clone by mistake produces an empty log that reads exactly like
     "the hook never fired".
5. **Stop-gate check**: ask the model to do anything trivial and finish.
   - PASS = the turn end is blocked with
     `loop-eng stop-gate BLOCKED this stop (1/3)` and the `false` criterion's
     output tail, which since 0.11.0 names the criterion
     (`FAIL [red] always fails (exit 1)`); before 0.11.0 that tail was empty,
     so this line of the checklist was passing on no signal at all.
   - Headless equivalent (the block text goes to hook stderr, which `claude -p`
     does not print): assert the disk instead — `.loop/results.json` carries
     `"generated_by": "run-contract.sh"` with `"all_green": false`.
   - **Do NOT use "`.loop/gate-count` reaches 3" as the headless PASS signal, and
     do not expect `.loop/active` to survive** (both were in this checklist and
     both misread a healthy run as a failure, observed 2026-09-19 on 0.12.0).
     `gate-count` is deleted by the ceiling path itself — the 4th stop attempt
     prints "block ceiling reached", clears the counter and allows — so a session
     that runs past three blocks ends with the file ABSENT, not at `3`. And the
     block reason explicitly offers the model a legitimate exit ("record it in
     `.loop/state.md` and remove `.loop/active`"), which a capable model takes,
     leaving `active` gone and a stop-rule entry in `state.md`. Both are the gate
     working. If you need the block count as a fact rather than an inference,
     instrument the LIVE cached `stop-gate.sh` the way step 4 instruments the
     evidence-gate — append a marker at the two block exits and at the ceiling —
     and assert the marker log (`BLOCK-red n=1..3`, then `CEILING-RELEASE`).
   - Teardown (human terminal): `rm -f .loop/active .loop/criteria.sha256 .loop/gate-count`
6. **`${CLAUDE_PLUGIN_ROOT}` in command bodies**: in the session run
   `/autoloop create hello.txt containing "hi"; acceptance: test -f hello.txt`.
   - PASS = the arm step reports `stop-gate armed` (the command expanded
     `${CLAUDE_PLUGIN_ROOT}/skills/loop-eng/scripts/arm-contract.sh`), the
     loop reaches ALL GREEN, and the session can stop freely afterwards
     (gate lifted itself).
7. **Record**: note the result (pass/fail + Claude Code version) in the
   CHANGELOG entry for the release. On first-ever pass, flip roadmap B3-1.
8. **Cleanup**: `/plugin uninstall loop-eng` (optional), `rm -rf ~/tmp/loop-smoke`.

## 2. Ship

- [ ] ff-merge to `main`, push, wait for CI green.
- [ ] Annotated tag: `git tag -a vX.Y.Z -m "vX.Y.Z"` + `git push origin vX.Y.Z`.
- [ ] Wait for the **release gate** (`.github/workflows/release.yml`, fires on
      the `v*` tag): it re-runs the full suite against the TAGGED tree and
      asserts that the three manifest fields, the CHANGELOG's dated section and
      the tag all say the same version — and that no `## Unreleased` section is
      left behind.
      Select the gate run by the TAG, for the same reason as step 0's sha
      filter and with a second recorded incident behind it: right after a tag
      push, `--limit 1` returns the PREVIOUS tag's gate run, already
      `completed success`, so the wait-loop reports the new tag verified before
      its gate has started (0.16.1).
      ```
      gh run list --workflow=release.yml --limit 10 \
        --json headBranch,status,conclusion \
        --jq '.[] | select(.headBranch=="vX.Y.Z")'
      ```
      Empty output means "not registered yet" — re-run it.
      A red gate means **do not publish**: delete the tag, fix, re-tag. A tag
      whose manifests disagree with it installs cleanly and then serves the
      wrong version forever, which is why this is the one step that is now a
      machine's rather than a line in this list.
- [ ] `gh release create vX.Y.Z --title "vX.Y.Z" --notes "<CHANGELOG section>"`.
      Still manual, deliberately: the gate has `contents: read` and publishes
      nothing, so the decision to publish and the wording of the notes stay a
      person's.

## 3. Post-ship

- [ ] Re-run the live-install smoke against the RELEASED version if step 1 was
      run against a pre-release commit.
- [ ] Prove the artifact users get IS the tag, in one command — install into a
      second, fresh `CLAUDE_CONFIG_DIR`, then:
      ```
      CFG2=~/tmp/loop-ship-verify        # the SECOND, uninstrumented config dir
      git archive vX.Y.Z --prefix=tagtree/ | tar -x -C /tmp
      diff -r --exclude=.git /tmp/tagtree \
        "$CFG2/plugins/cache/loop-eng/loop-eng/X.Y.Z"
      ```
      Expect exactly one difference: `Only in …/X.Y.Z: .in_use`, a marker the
      platform writes. Anything else means the install is not the tag. This is
      cheaper than re-running all six steps and answers a different question
      than they do — they test behavior, this tests identity, which is what
      makes an abbreviated post-ship defensible when §1 already passed on the
      same content.
- [ ] Save a ship-runbook memory entry if anything deviated from this file.
