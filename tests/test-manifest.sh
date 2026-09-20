#!/usr/bin/env bash
# manifest: the release-blocking facts about .claude-plugin/ that nothing else
# in this suite reads.
#
# Two of these were manual checklist lines in RELEASING.md — "version bump
# touches THREE fields across TWO files", "every .md has frontmatter" — and a
# checklist line is a thing a human remembers, not a thing that fails. A stale
# marketplace version ships a plugin the marketplace advertises at the wrong
# number; a component with no frontmatter loads as nothing at all, silently.
#
# JSON is parsed with python3 by EXPLICIT PATH, never by "the Nth line matching
# version": plugins[] is an array of objects, and a positional grep silently
# reads the wrong field the day a second plugin or a nested array is added.
set -u
. "$(dirname "$0")/lib.sh"

cd "$PLUGIN_ROOT" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
  # Not a benign skip: with no parser this suite checks nothing about the two
  # manifests, and report() now refuses to call that green. Install python3 to
  # run it — a host that cannot read the manifests cannot vouch for them.
  echo "test-manifest: python3 not available — the manifests cannot be parsed, so nothing here was checked" >&2
  report "test-manifest"
  exit $?
fi

# --- manifest agreement, on any plugin dir -----------------------------------
# Echoes "<plugin.name> <plugin.version> <mkt.metadata.version> <mkt.plugins[0].name> <mkt.plugins[0].version>"
# or "ERROR <what>". Takes a directory so the negative cases below can run it
# against a deliberately broken sandbox copy.
manifest_fields() {
  python3 - "$1" <<'PY'
import json, sys, pathlib
root = pathlib.Path(sys.argv[1])
try:
    p = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
    m = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
    entries = m["plugins"]
    if not isinstance(entries, list) or not entries:
        print("ERROR marketplace.plugins-not-a-nonempty-array"); sys.exit(0)
    # Select the entry BY NAME, not by index: entry order is not a contract.
    match = [e for e in entries if e.get("name") == p.get("name")]
    if len(match) != 1:
        print("ERROR no-unique-marketplace-entry-for-%s" % p.get("name")); sys.exit(0)
    e = match[0]
    print(p.get("name", ""), p.get("version", ""),
          m.get("metadata", {}).get("version", ""),
          e.get("name", ""), e.get("version", ""))
except Exception as exc:
    print("ERROR %s" % type(exc).__name__)
PY
}

read -r p_name p_ver m_meta_ver e_name e_ver <<EOF
$(manifest_fields .)
EOF

assert_eq "loop-eng" "$p_name" "plugin.json declares the plugin name"
assert_eq "$p_name" "$e_name" "marketplace entry name matches plugin.json name"
# The three version fields RELEASING.md step 0 says a bump must touch.
assert_eq "$p_ver" "$m_meta_ver" "marketplace metadata.version matches plugin.json version"
assert_eq "$p_ver" "$e_ver" "marketplace plugins[].version matches plugin.json version"
case "$p_ver" in
  [0-9]*.[0-9]*.[0-9]*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: version '$p_ver' is not X.Y.Z" >&2 ;;
esac

# CHANGELOG must carry a DATED section for the version being shipped, which is
# what RELEASING.md step 0 actually asks for ("a dated section for the version").
# A bare `grep "^## $p_ver"` was weaker than the line it mechanizes on two counts
# the pre-ship reviewer drove green: it is a PREFIX match, so `## 0.12.2-rc1`
# satisfies a 0.12.2 release, and it accepts an undated `## 0.12.2` — the exact
# omission a hurried release makes. Anchor the full heading, date included.
#
# `$p_ver` interpolates UNESCAPED on purpose, so its dots are regex-any. That is
# harmless: the shape check above already proved $p_ver is digits-and-dots, so
# the only characters its dots can over-match are other digits. The escaped form
# `${p_ver//./\.}` was tried and does behave identically on bash 3.2.57 and
# 5.3.9 (measured: both expand to `0\.12\.2`, both match) — but it is the same
# pattern-substitution-with-backslash-replacement shape CLAUDE.md warns readers
# away from for json_str, and a construct costing a paragraph to defend is not
# worth using where plain interpolation is provably safe.
#
# The separator accepts an em-dash or a hyphen on purpose: RELEASING.md asks for
# a dated section, not for a typographic convention, so pinning `—` would
# enforce a rule the checklist does not state.
# Braces are load-bearing, not style: `$p_ver[[:space:]]` reads as an array
# expansion (shellcheck SC1087, an *error*-level finding, so run-all.sh's
# `shellcheck -S error` gate fails on it even though every assertion passes).
if grep -qE "^## ${p_ver}[[:space:]]+[—-][[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$" CHANGELOG.md 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: CHANGELOG.md has no dated '## $p_ver — <date>' section" >&2
fi

# --- negative cases: the check must actually catch a drifted manifest --------
# Without these the four assertions above are a tautology on a healthy repo and
# would keep passing if manifest_fields silently started returning blanks.
SB=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-manifest.XXXXXX")
# VCFG is declared here rather than beside its use so the one EXIT trap covers
# it: an inline `rm` is never reached by a killed suite.
VCFG=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-vcfg.XXXXXX")
trap 'rm -rf "$SB" "$VCFG"' EXIT
mkdir -p "$SB/.claude-plugin"
cp .claude-plugin/plugin.json .claude-plugin/marketplace.json "$SB/.claude-plugin/"

# (a) metadata.version drifts behind plugin.json
python3 - "$SB" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1], ".claude-plugin", "marketplace.json")
m = json.loads(p.read_text()); m["metadata"]["version"] = "0.0.1"
p.write_text(json.dumps(m))
PY
read -r _ d_pver d_mver _ _ <<EOF
$(manifest_fields "$SB")
EOF
if [ "$d_pver" != "$d_mver" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: a drifted metadata.version was not detected" >&2; fi

# (b) the marketplace entry for this plugin disappears
python3 - "$SB" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1], ".claude-plugin", "marketplace.json")
m = json.loads(p.read_text()); m["plugins"] = [{"name": "something-else", "version": "9.9.9"}]
p.write_text(json.dumps(m))
PY
case "$(manifest_fields "$SB")" in
  ERROR\ no-unique-marketplace-entry*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: a missing marketplace entry was not detected" >&2 ;;
esac

# --- every shipped component .md carries frontmatter -------------------------
# A command/agent/skill without a `---` block loads as nothing; Claude Code
# reports it as a warning, so nothing fails until a user notices the command is
# missing. Derived from the directories the manifest ships, not a fixed list.
for f in commands/*.md agents/*.md skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  if [ "$(head -1 "$f")" = "---" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $f has no frontmatter block" >&2; fi
done

# An agent's `name:` is what the Task tool dispatches on; a rename of the file
# that forgets the field leaves commands/ referring to an agent that resolves
# to the old name.
for f in agents/*.md; do
  [ -e "$f" ] || continue
  want="${f##*/}"; want="${want%.md}"
  got=$(sed -n '1,/^---$/p' "$f" | sed -n 's/^name:[[:space:]]*//p' | head -1)
  assert_eq "$want" "$got" "agent $f declares name: matching its filename"
done

# --- the platform validator, when it is installed ----------------------------
# Mirrors run-all.sh's shellcheck convention: a real gate where the tool exists,
# a skip with a note where it does not. Credential-free (verified against an
# empty CLAUDE_CONFIG_DIR), so it needs no auth in CI.
#
# Deliberately NOT `--strict`: strict fails on ONE warning this repo cannot
# remove — CLAUDE.md at the plugin root, which is this repo's own dev guidance
# and must stay at the root for Claude Code to load it here. The plugins
# reference documents both that behavior and the absence of any exclude/suppress
# mechanism. So assert the strict-grade fact directly instead: zero errors
# anywhere, and that one known warning as the ONLY warning. A second warning
# fails the build, which is the signal a release wants.
if command -v claude >/dev/null 2>&1; then
  vout=$(CLAUDE_CONFIG_DIR="$VCFG" claude plugin validate .claude-plugin/plugin.json --json 2>/dev/null)
  verdict=$(printf '%s' "$vout" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNPARSEABLE"); raise SystemExit
errs, warns = [], []
for block in [d.get("manifest") or {}] + (d.get("contents") or []):
    errs += [e.get("message", "") for e in block.get("errors") or []]
    warns += [w.get("message", "") for w in block.get("warnings") or []]
if errs:
    print("ERRORS " + " | ".join(errs)); raise SystemExit
known = "CLAUDE.md at the plugin root is not loaded as project context"
extra = [w for w in warns if known not in w]
print("EXTRA " + " | ".join(extra) if extra else "CLEAN")
')
  assert_eq "CLEAN" "$verdict" "claude plugin validate: no errors, no unexpected warnings"
else
  echo "  SKIP: claude CLI not installed — platform validation not run" >&2
fi

report "test-manifest"
