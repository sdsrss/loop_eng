# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

loop-eng is a **Claude Code plugin** (not an app). It ships two self-driving
loops as slash commands plus the hook machinery that mechanically enforces their
completion contracts. Everything is POSIX shell + Markdown — no compiled
artifact, no runtime beyond bash. Two bash floors: the hooks + contract scripts
are **bash 3.2-compatible** (stock macOS; CI's `test-bash32` job is the ground
truth), while the unattended drivers require **`bash >= 4.4`** (empty-array
expansion under `set -u`).

## Testing

```
bash tests/run-all.sh          # bash -n syntax + shellcheck -S warning + every tests/test-*.sh
bash tests/test-run-contract.sh   # run ONE suite directly
```

`run-all.sh` collects scripts via `git ls-files '*.sh'`, so a **new script must
be `git add`ed before shellcheck will cover it**. shellcheck is optional (skipped
with a note if absent). Each `tests/test-*.sh` sources `tests/lib.sh`, builds a
throwaway git repo with `mk_sandbox_repo`, and cleans it on a `trap ... EXIT` —
tests must never touch the real tree, `~/.claude/`, or real systemd (the timer
tests set `LOOP_ENG_TIMER_NO_SYSTEMCTL=1` + a fake `XDG_CONFIG_HOME`).

### Checking the bash 3.2 floor locally

```
docker run --rm -v "$PWD":/repo:ro bash:3.2 sh -c '
  apk add --no-cache git coreutils grep sed findutils python3 jq >/dev/null 2>&1
  cp -r /repo /work && cd /work
  git config --global user.email t@t; git config --global user.name t
  for t in tests/test-arm-contract.sh tests/test-evidence-gate.sh \
           tests/test-run-contract.sh tests/test-stop-gate.sh \
           tests/test-hooks-json.sh tests/test-update-notify.sh; \
    do /usr/local/bin/bash "$t"; done'
```

`bash:3.2` is a real 3.2.57 — the same release stock macOS ships — so this
settles the bash-version axis without waiting for CI. Install the parsers:
without `jq`/`python3` the evidence-gate takes its documented fail-open path and
every deny assertion "fails" for the wrong reason. Alpine's musl userland is
**not** BSD, so the macOS coreutils axis (BSD `sed`/`find`, `wc` padding,
`gtimeout`, `/private/var` canonicalization) still belongs to CI's macOS legs.

**Never use `BASH_COMPAT=3.2` as a substitute.** It restores bash ≤4.2
pattern-substitution semantics for replacement backslashes (changed in 4.3),
producing behavior *neither* real 3.2.57 *nor* 5.x exhibits: `${s//\\/\\\\}` in
`run-contract.sh`'s `json_str` stops doubling backslashes, and the TAB-escaping
assertion fails against working code. Acting on that false positive would break
`json_str` on every real bash — which is exactly what the "do not
portability-rewrite it speculatively" note at `run-contract.sh:51` warns about.

## Dual-source layout — the one gotcha that bites

The **repo root is the canonical plugin source** (`commands/`, `agents/`,
`hooks/`, `skills/`). `.claude/` is a **synced copy** used only to dogfood the
plugin inside this very repo without installing it. Edit the root, then:

```
bash scripts/sync-local.sh     # root -> .claude/ (settings.json left untouched)
```

Editing files under `.claude/` directly is a mistake — the next sync overwrites
them. `.loop/` is this repo's own runtime loop state (gitignored); `.code-graph/`
and the `.claude/plugin_*.md` + sentinel blocks below are tooling, not source.

There may be a THIRD copy, and when there is, it is the one that actually
enforces. If loop-eng is installed as a marketplace plugin (user scope), the
hooks firing in live sessions — including sessions in this repo — load from the
plugin CACHE under `~/.claude/plugins/`, which lags the repo until
`/plugin update`. After changing `hooks/` or `skills/loop-eng/scripts/`, assume
live enforcement is still the last released version until you update.

**Check, do not assume — this machine may not have it installed at all**
(verified absent 2026-09-19, which makes the paragraph above a trap in the
other direction: an agent that assumes a stale cache is enforcing will
misread which copy it is testing):

```
claude plugin list | grep -A2 loop-eng    # installed? at what version?
```

Whatever the answer, `arm-contract.sh` prints `armed from <path>` on every arm,
so a loop always shows which copy it actually ran — prefer that line over any
belief about the install state. One more distinction the path makes visible: a
`directory`-source marketplace runs the plugin straight from the source
directory and never executes the version-pinned `plugins/cache/` copy, while a
GitHub source is the opposite (see RELEASING.md §1).

## Architecture: two loops, enforced by mechanism not trust

Entry points are `commands/autoloop.md` and `commands/polish.md`; shared logic
lives in the `loop-eng` skill (`skills/loop-eng/SKILL.md` + `scripts/`).

- **`/autoloop`** runs a **builder → checker** cycle. They are separate subagents
  (`agents/loop-builder.md`, `agents/loop-checker.md`) and the checker has **no
  Write/Edit tools** — maker/checker separation is enforced by the agent tool
  whitelist, not by prompting. Loops until ALL GREEN or one of six stop rules
  fires (max 5 rounds).
- **`/polish`** runs **reviewer → verifier → fix**. Four review lenses each get
  an independent `loop-reviewer` context (no cross-talk); every finding is handed
  to an adversarial `loop-verifier` that tries to *refute* it before it enters
  the fix queue. Behavior-preserving: anything that would change a public
  contract (incl. deleting an exported symbol) is deferred to the human.

**The completion invariant (the reason this plugin exists).** "Done" is a
machine-written fact, never a model claim. Three layers, all in `hooks/` +
`skills/loop-eng/scripts/`:

1. `arm-contract.sh` writes `.loop/criteria.tsv` (binary criteria + verify
   commands) and records `.loop/criteria.sha256` (a hash-lock), then drops
   `.loop/active`.
2. `hooks/evidence-gate.sh` (PreToolUse on Write/Edit/Bash) **denies model writes**
   to `.loop/results.json`, `.loop/evidence/`, and the armed `criteria.tsv` while
   `.loop/active` exists. Escape hatch: `LOOP_ENG_DISABLE_EVIDENCE_GATE=1`.
3. `hooks/stop-gate.sh` (Stop) re-runs `run-contract.sh` on every stop attempt
   and blocks exit (exit 2, failure fed back) until the contract passes. It fails
   **closed** on a vacuous/empty contract, on a *partly parsed* one (any criteria
   line that is not blank, not a `#comment`, and yields no id or no command
   column — the usual slip is spaces where TABs belong), on a hash-lock
   mismatch, and on a `criteria.tsv` whose runner it cannot find (a broken
   install must not silently disarm the gate — only a loop armed with *no*
   contract at all still allows the stop), with a hard ceiling of 3 blocks
   (Claude Code force-allows after 8, so the gate can't deadlock a session).
   The rule they share: a contract
   the runner could not fully parse is never reported green, because nothing
   downstream can tell "all criteria passed" from "the ones that parsed passed".

So `passes: true` can only come from actually running the verify command — it
cannot be typed. When changing any of these three scripts, keep the fail-closed
behavior and re-run the full test suite; the invariant is the product.

Unattended entry points (`scripts/unattended-{polish,autoloop}.sh`) are
report-only / no-build unless explicitly opted in (`LOOP_ENG_ALLOW_AUTOFIX=1` /
`LOOP_ENG_ALLOW_AUTOBUILD=1`) and refuse dirty trees. `install-timer.sh` /
`uninstall-timer.sh` register them as a `systemd --user` timer.

## Release

CI (`.github/workflows/test.yml`) runs the full suite on ubuntu + macOS plus a
stock-bash-3.2 job; releases themselves are manual — `RELEASING.md` is the
authoritative checklist (pre-flight, marketplace-install smoke, tag,
`gh release create`). A version bump touches **three manifest fields across
two files**: `.claude-plugin/plugin.json` (`version`) and
`.claude-plugin/marketplace.json` (`metadata.version` + `plugins[0].version`).

### Packaging scope

A git-based marketplace install ships the **full git tree** — the `/plugin
install` clone is a wholesale `git clone`/`git pull` of the repo, so every
tracked path lands in the user's plugin cache, `tests/` (the ~40KB of
`test-*.sh` suites) included. There is **no way to exclude tracked paths**: the
plugin manifest format (`.claude-plugin/plugin.json` / `marketplace.json`) has
no `files`/`include`/`exclude` field and Claude Code honours no `.claudeignore`
— the `claude-code-plugin-dev` skill documents no such mechanism and states the
install "copies the full tree", confirmed empirically (installed cache under
`~/.claude/plugins/cache/loop-eng/` contains all `tests/`). This is acceptable
and left as-is: the suites are tiny text files, carry no runtime cost (never
sourced by any command/hook), and hold no secrets. Untracking `tests/` is NOT
an option — CI runs them. Do not add a build/packaging step for ~40KB.

---

The two blocks below are **auto-managed** by the claude-mem-lite and code-graph
plugins (sentinel-wrapped). Do not hand-edit inside the sentinels; they are
regenerated by those plugins' adopt hooks.

<!-- claude-mem-lite:begin v1 -->
## claude-mem-lite — persistent memory

PreToolUse hooks already run `mem_recall` for past lessons before Read/Edit/Write. The calls worth making proactively:

| When | Call |
|------|------|
| Before Edit/Write | hook already recalled; if a `#NN` lesson was injected, cite `#NN` next time you produce user-visible text (citing = adopting the feedback; uncited lessons decay) |
| After fixing a non-trivial bug | `mem_save(type="bugfix", lesson_learned="<root cause + fix>", importance=2)` |
| After a non-obvious architecture decision | `mem_save(type="decision", lesson_learned="<constraint + tradeoff>")` |
| Deferring to a future session | `mem_defer({title, priority:1|2|3, detail})`; when fixed, add `closes_deferred=[N]` to `mem_save` |
| Looking up past work / history | `mem_search "keywords"` · `mem_recent` · `mem_timeline` |

Path cost is round-trips, not milliseconds: the PreToolUse hook above already recalls (0 calls) — prefer it. For an explicit query, if these `mem_*` tools are deferred behind ToolSearch this session, the Bash CLI `claude-mem-lite` is one call vs two (ToolSearch + call); the MCP server instructions carry the absolute path to use when it is not on PATH.

Full tool + CLI tables, citation/decay rules, and save discipline → `.claude/plugin_claude_mem_lite.md`
<!-- claude-mem-lite:end -->

<!-- code-graph-mcp:begin v2 -->
## Code Graph (repo-wide AST index)

AST + FTS + vector index of the whole repo — prefer over multi-round Grep/Read for
structural queries (LSP only sees open files; this sees everything). Fastest path = Bash CLI:

| Intent | Command |
|--------|---------|
| Who calls X / what X calls | `code-graph-mcp callgraph X` |
| Impact before editing a fn | `code-graph-mcp impact X` |
| Unfamiliar dir / module | `code-graph-mcp overview <dir>` |
| Symbol source / signature | `code-graph-mcp show X` |
| Concept search (no exact name) | `code-graph-mcp search "…"` (vector: MCP `semantic_code_search`) |
| grep + AST context | `code-graph-mcp grep "pat" [paths] [-t lang] [-g glob] [-c]` |

Not on PATH? A plugin-only install keeps its own copy — same commands, run
`~/.cache/code-graph/bin/code-graph-mcp` (or `npm i -g @sdsrs/code-graph` once).

Still use Grep for literal strings/regex in non-code files; still Read files you'll edit.
Full command + MCP-tool table: `.claude/plugin_code_graph_mcp.md`
<!-- code-graph-mcp:end -->
