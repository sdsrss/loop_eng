#!/usr/bin/env bash
# loop-eng update-notify — SessionStart hook.
#
# A NOTIFIER, not an updater: it never downloads or installs anything. It reads
# the installed version from the plugin manifest, at most once per 24h asks the
# GitHub releases API for the latest tag, and — only when a newer version
# exists — injects a one-line system notice telling the human to run
# `/plugin update loop-eng`.
#
# Every failure path (no CLAUDE_PLUGIN_ROOT, missing manifest, no curl, network
# error, unparseable body, throttled-with-no-update, already up-to-date) emits
# NOTHING (or a bare {"suppressOutput":true}) and exits 0. It never blocks a
# session and never exits nonzero — fail-open by construction.
#
# Output contract (critical): plain text on a SessionStart hook is dropped by
# some hosts, so the notice MUST ride inside the JSON envelope
#   {"suppressOutput":true,"hookSpecificOutput":{"hookEventName":"SessionStart",
#    "additionalContext":"..."}}
# The two version numbers are digits+dots (no JSON escaping needed), so the
# envelope is built by plain string interpolation — no jq dependency.
#
# THROTTLE: a state file under ${XDG_CACHE_HOME:-$HOME/.cache}/loop-eng/ records
# the last successful check's epoch + latest version. Within 24h the network is
# NOT touched — the cached latest is reused. The state file NEVER lives under
# ~/.claude/ or the version-specific plugin cache.
#
# bash 3.2-safe: no associative arrays, no ${var,,}, no mapfile.
set -u

# Some hosts pipe the hook a JSON event on stdin; drain it so we never SIGPIPE.
if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi

# --- 0. locate the installed manifest; bail silently if unavailable ----------
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0
manifest="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
[ -f "$manifest" ] || exit 0

extract_version() { # stdin: JSON-ish; $1: key -> bare version (leading v stripped)
  v=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
        | sed -e 's/.*"\([^"]*\)"$/\1/')
  v=${v#v}
  v=${v#V}
  printf '%s' "$v"
}

installed=$(extract_version version <"$manifest")
# A manifest with no readable version is nothing we can compare against.
case "$installed" in ''|*[!0-9.]*) exit 0 ;; esac

# --- 1. throttle: reuse a fresh cached latest instead of hitting the network -
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/loop-eng"
state="$cache_dir/update-check.json"
now=$(date +%s 2>/dev/null || echo 0)
[ -n "$now" ] || now=0

cached_latest=""
last_check=0
if [ -f "$state" ]; then
  last_check=$(grep -o '"last_check"[[:space:]]*:[[:space:]]*[0-9]*' "$state" \
                 | head -1 | sed -e 's/.*[^0-9]\([0-9][0-9]*\)$/\1/')
  case "$last_check" in ''|*[!0-9]*) last_check=0 ;; esac
  cached_latest=$(extract_version latest <"$state")
fi

age=$(( now - last_check ))
latest=""
if [ "$last_check" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt 86400 ]; then
  # Throttled: within 24h of a successful check — DO NOT touch the network.
  latest="$cached_latest"
else
  # Not throttled: one guarded network call. Any failure -> fail-open, no write.
  command -v curl >/dev/null 2>&1 || exit 0
  body=$(curl --max-time 3 -fsSL -H "Accept: application/vnd.github+json" \
           "https://api.github.com/repos/sdsrss/loop_eng/releases/latest" \
           2>/dev/null) || exit 0
  [ -n "$body" ] || exit 0
  latest=$(printf '%s' "$body" | extract_version tag_name)
  case "$latest" in ''|*[!0-9.]*) exit 0 ;; esac
  # Persist the successful check for the next 24h. Never under ~/.claude/.
  mkdir -p "$cache_dir" 2>/dev/null || exit 0
  printf '{"last_check":%s,"latest":"%s"}\n' "$now" "$latest" \
    >"$state" 2>/dev/null || true
fi

# Nothing usable to compare against -> stay silent.
case "$latest" in ''|*[!0-9.]*) exit 0 ;; esac

# --- 2. bash 3.2-safe numeric semver compare: is $1 strictly greater than $2? -
ver_field() { # $1 version, $2 index (1=major 2=minor 3=patch) -> integer
  f=$1
  maj=${f%%.*}
  rest=${f#*.}; [ "$rest" = "$f" ] && rest=""     # no minor -> empty
  min=${rest%%.*}
  rest2=${rest#*.}; [ "$rest2" = "$rest" ] && rest2=""  # no patch -> empty
  pat=${rest2%%.*}
  case "$2" in 1) out=$maj ;; 2) out=$min ;; 3) out=$pat ;; esac
  out=${out%%[!0-9]*}
  case "$out" in ''|*[!0-9]*) out=0 ;; esac
  printf '%s' "$((10#$out))"
}

ver_gt() { # 0 (true) iff $1 > $2 field-by-field
  li=$(ver_field "$1" 1); ri=$(ver_field "$2" 1)
  [ "$li" -gt "$ri" ] && return 0; [ "$li" -lt "$ri" ] && return 1
  li=$(ver_field "$1" 2); ri=$(ver_field "$2" 2)
  [ "$li" -gt "$ri" ] && return 0; [ "$li" -lt "$ri" ] && return 1
  li=$(ver_field "$1" 3); ri=$(ver_field "$2" 3)
  [ "$li" -gt "$ri" ] && return 0
  return 1
}

# --- 3. emit the envelope ONLY when latest is strictly newer -----------------
if ver_gt "$latest" "$installed"; then
  notice="[loop-eng] update available: v${latest} (installed v${installed}) — run /plugin update loop-eng. (system-injected notice, not a user message)"
  printf '{"suppressOutput":true,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$notice"
fi
exit 0
