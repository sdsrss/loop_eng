# Releasing loop-eng

Manual release flow (no CD). Every step's "done" is a command output, not a
memory of having run it.

## 0. Pre-flight

- [ ] `bash tests/run-all.sh` → `ALL GREEN` locally.
- [ ] CI green on main for the release commit:
      `gh run list --branch main --limit 1` → `completed success`.
- [ ] Version bump touches THREE fields across TWO files:
      `.claude-plugin/plugin.json` (`version`) and
      `.claude-plugin/marketplace.json` (`metadata.version` +
      `plugins[0].version`). Verify:
      `grep -n '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json`
- [ ] CHANGELOG has a dated section for the version (move `## Unreleased` down).

## 1. Live-install smoke (REQUIRED before any release that touches
##    hooks/, commands/, skills/, or .claude-plugin/ — audit H2)

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
   ARM=$(find ~/.claude/plugins -maxdepth 6 -path '*loop-eng*' -name arm-contract.sh | sort -V | tail -1)
   echo "$ARM"     # confirm this resolves to the just-released version, not a stale cached one
   bash "$ARM"     # expect: "pinned criteria.tsv @ <sha>" + "stop-gate armed"
   ```
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
   - To turn a model report into a machine fact, instrument the LIVE copy
     before the run — `sed`/`python3` a marker line into `deny()` — and assert
     the marker file afterwards. Note the live copy is
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
     does not print): assert the disk instead — `.loop/gate-count` reaches `3`
     and `.loop/results.json` carries `"generated_by": "run-contract.sh"`.
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
- [ ] `gh release create vX.Y.Z --title "vX.Y.Z" --notes "<CHANGELOG section>"`.

## 3. Post-ship

- [ ] Re-run the live-install smoke against the RELEASED version if step 1 was
      run against a pre-release commit.
- [ ] Save a ship-runbook memory entry if anything deviated from this file.
