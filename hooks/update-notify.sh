#!/usr/bin/env bash
# loop-eng update-notify — SessionStart hook.
#
# A NOTIFIER, not an updater: it never downloads or installs anything. It reads
# the installed version from the plugin manifest, asks the GitHub releases API
# for the latest tag on a throttle (see THROTTLE below: 24h after a successful
# check, 1h after a failed one — so "once per 24h" is the best case, not the
# floor), and — only when a newer version exists — injects a one-line system
# notice telling the human to run `/plugin update loop-eng`.
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
# the last successful check's epoch + latest version, and the epoch of the last
# FAILED one. Within 24h of a success the network is NOT touched — the cached
# latest is reused; within 1h of a failure it is not touched either, so an
# offline machine pays one curl an hour instead of one per session. The state
# file NEVER lives under ~/.claude/ or the version-specific plugin cache.
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
# HOME is guarded because this file runs under `set -u` and promises above to
# never exit nonzero. Bash evaluates this fallback only when XDG_CACHE_HOME is
# unset or empty, and a bare $HOME there is fatal when HOME is UNSET (an empty
# HOME expands fine) — so a SessionStart in an environment that strips HOME
# killed the hook at this line instead of failing open. With the guard the dir
# resolves to an unwritable /.cache, and write_state's `mkdir -p … || return 0`
# takes it from there, which is the fail-open path every other failure uses.
cache_dir="${XDG_CACHE_HOME:-${HOME:-}/.cache}/loop-eng"
state="$cache_dir/update-check.json"
now=$(date +%s 2>/dev/null || echo 0)
[ -n "$now" ] || now=0

read_num() { # $1 key -> non-negative integer from $state, 0 when absent/garbage
  n=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$state" \
        | head -1 | sed -e 's/.*[^0-9]\([0-9][0-9]*\)$/\1/')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

write_state() { # $1 last_check  $2 latest  $3 last_fail
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  printf '{"last_check":%s,"latest":"%s","last_fail":%s}\n' "$1" "$2" "$3" \
    >"$state" 2>/dev/null || true
  return 0
}

cached_latest=""
last_check=0
last_fail=0
if [ -f "$state" ]; then
  last_check=$(read_num last_check)
  last_fail=$(read_num last_fail)
  cached_latest=$(extract_version latest <"$state")
fi

age=$(( now - last_check ))
fail_age=$(( now - last_fail ))
latest=""
if [ "$last_check" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt 86400 ]; then
  # Throttled: within 24h of a successful check — DO NOT touch the network.
  latest="$cached_latest"
elif [ "$last_fail" -gt 0 ] && [ "$fail_age" -ge 0 ] && [ "$fail_age" -lt 3600 ]; then
  # Backed off: the last attempt FAILED less than an hour ago.
  #
  # Every failure path below used to `exit 0` before reaching the state write,
  # so nothing recorded that an attempt had been made. On a machine that is
  # simply offline — a plane, a locked-down network, a GitHub 403 — that meant
  # a 3-second curl at the start of every single session, forever, with no
  # trace of why. An hour is the deliberate middle: long enough that a flight
  # costs one call rather than one per session, short enough that a transient
  # blip does not cost a day of notices the way reusing the 24h window would.
  latest="$cached_latest"
else
  # Not throttled: one guarded network call. Every failure is fail-open AND
  # recorded, so the next session backs off instead of repeating it.
  command -v curl >/dev/null 2>&1 || exit 0
  body=$(curl --max-time 3 -fsSL -H "Accept: application/vnd.github+json" \
           "https://api.github.com/repos/sdsrss/loop_eng/releases/latest" \
           2>/dev/null) || body=""
  if [ -z "$body" ]; then
    write_state "$last_check" "$cached_latest" "$now"
    exit 0
  fi
  latest=$(printf '%s' "$body" | extract_version tag_name)
  # A tag this cannot compare — empty, garbage, or carrying a pre-release
  # suffix like v1.3.0-rc1 (extract_version keeps the suffix, which fails the
  # digits-and-dots test). Still no notice: announcing "1.3.0 is available"
  # when the release is 1.3.0-rc1 would be wrong. But it IS an attempt, and
  # before this it was discarded without one being recorded — so a single
  # mis-published pre-release meant a curl every session until someone noticed.
  # `releases/latest` does not return pre-releases, so that is the only route.
  case "$latest" in
    ''|*[!0-9.]*)
      write_state "$last_check" "$cached_latest" "$now"
      exit 0 ;;
  esac
  # Persist the successful check for the next 24h, clearing the failure stamp.
  # Never under ~/.claude/.
  write_state "$now" "$latest" 0
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
