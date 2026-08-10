#!/usr/bin/env bash
# Regression test for team_broadcast_install_gap() in
# hooks/surface-stale-automation-failures.py.
#
# WHY THIS EXISTS: team_broadcast_findings() infers health from a log file
# (~/.claude/logs/team-broadcast-daily.log). A machine where team-broadcast was
# NEVER installed has no log file for the same reason a HEALTHY, quiet install
# has no log file yet: nothing has run. Both read as team_broadcast_findings()
# returning [] -- so "never installed" produced zero signal, on every session,
# indefinitely. That is a stricter silence than an outright failure would have
# been. team_broadcast_install_gap() checks installation directly (script
# presence, then the launchd job) instead of inferring it from a log.
#
# Asserts, in order:
#   1. MISSING: auto-send.py absent -> FIRES, names the script path, points at
#      the setup runbook.
#   2. CRON-GAP: script present, launchd job not registered -> FIRES, names the
#      cron gap specifically, and does NOT claim session-close broadcasts (a
#      separate, live-invoked path) are affected.
#   3. NEG-CONTROL: script present, launchd job registered -> SILENT (no
#      cry-wolf on a healthy install).
#   4. END-TO-END: the finding reaches the real SessionStart entrypoint
#      (main()'s systemMessage), not just the helper function in isolation.
#
# launchctl is macOS-only; CI runs ubuntu (CONTRIBUTING.md). A fake launchctl on
# PATH makes cases 2-4 deterministic on any OS instead of skipping Linux CI.
# Stdlib python3 + bash only. No network, no real launchd/git. Tmpdir on exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/surface-stale-automation-failures.py"
# HOME alone does not sandbox ~ on Windows — see lib/sandbox_home.sh.
# shellcheck source=tests/integration/lib/sandbox_home.sh
. "$SCRIPT_DIR/lib/sandbox_home.sh"

PASS=0
FAIL=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1 :: $2"; }
assert_fires()  { case "$OUT" in *additionalContext*|*systemMessage*) ok "$1" ;; *) bad "$1" "no finding (out=${OUT:0:120})" ;; esac; }
assert_silent() { case "$OUT" in "") ok "$1" ;; *) bad "$1" "unexpected output (out=${OUT:0:120})" ;; esac; }
assert_has()    { case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2' (out=${OUT:0:150})" ;; esac; }
assert_lacks()  { case "$OUT" in *"$2"*) bad "$1" "unexpectedly present: '$2'" ;; *) ok "$1" ;; esac; }

newhome() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); mkdir -p "$d/.claude"; echo "$d"; }

# fake_launchctl HOME REGISTERED_LABEL_OR_EMPTY -- puts a fake `launchctl` ahead
# of the real one on PATH. "list <label>" exits 0 iff label == REGISTERED
# (mirrors the real command's contract, confirmed against a real registered vs
# unregistered label: exit 0 vs exit 113).
fake_launchctl() {
  local home="$1" registered="$2" bin="$1/fakebin"
  mkdir -p "$bin"
  cat > "$bin/launchctl" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "list" ] && [ "\${2:-}" = "$registered" ] && [ -n "$registered" ]; then
  echo '{ "Label" = "'"\$2"'"; }'
  exit 0
fi
if [ "\$1" = "list" ] && [ -n "\${2:-}" ]; then
  echo "Could not find service \"\$2\" in domain for port" >&2
  exit 113
fi
exit 0
EOF
  chmod +x "$bin/launchctl"
}

# run_hook HOME -- invokes the real SessionStart entrypoint, sandboxed fakebin
# first on PATH so it beats any real launchctl on the runner.
run_hook() {
  local home="$1"
  OUT="$(PATH="$home/fakebin:$PATH" run_sandboxed "$home" python3 "$HOOK" <<<'{}' 2>/dev/null)"
}

echo "=== precondition ==="
[ -f "$HOOK" ] && ok "hook exists" || bad "hook exists" "missing $HOOK"

echo "=== 1. MISSING: auto-send.py absent -> FIRES ==="
H1="$(newhome)"
fake_launchctl "$H1" ""   # irrelevant here: script-missing short-circuits before any launchctl call
run_hook "$H1"
assert_fires "fires when auto-send.py is absent"
assert_has   "names the missing script path" "team-broadcast/scripts/auto-send.py"
assert_has   "points at the setup runbook" "Team Broadcast Setup.md"

echo "=== 2. CRON-GAP: script present, launchd job NOT registered -> FIRES ==="
H2="$(newhome)"
mkdir -p "$H2/.claude/skills/team-broadcast/scripts"
touch "$H2/.claude/skills/team-broadcast/scripts/auto-send.py"
fake_launchctl "$H2" ""   # nothing registered
run_hook "$H2"
assert_fires "fires when the daily-broadcast launchd job is unregistered"
assert_has   "names the launchd label" "com.adelaida.team-broadcast-daily"
assert_has   "clarifies session-close broadcasts are unaffected" "unaffected"
assert_lacks "does not claim broadcasts are unreachable (that's case 1's wording)" "unreachable"

echo "=== 3. NEG-CONTROL: script present, launchd job registered -> SILENT ==="
H3="$(newhome)"
mkdir -p "$H3/.claude/skills/team-broadcast/scripts"
touch "$H3/.claude/skills/team-broadcast/scripts/auto-send.py"
fake_launchctl "$H3" "com.adelaida.team-broadcast-daily"
run_hook "$H3"
assert_silent "no finding when installed and the cron is registered (no cry-wolf)"

echo "=== 4. END-TO-END: reaches main()'s systemMessage, not just the helper ==="
H4="$(newhome)"
fake_launchctl "$H4" ""
run_hook "$H4"
assert_has "the missing-install finding rides the real systemMessage envelope" "systemMessage"
assert_has "carries the shared incident framing" "191-file strand"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
