#!/usr/bin/env bash
# Regression tests for ../scripts/humanos-update-check (run from anywhere).
#
# Contract under test (WOR-19):
#   * a failed source must never be reported as "clean";
#   * a degraded run must not overwrite the cache;
#   * when degraded, the previous cache content is echoed so the badge keeps
#     the last known state;
#   * checkupdates rc=2 means "nothing to do", rc=1 means "could not check".
#
# Stub-based cases replace the network tools with scripts in a private PATH;
# the "offline" case uses a network namespace. Set RUN_ONLINE=1 to also run the
# real online check.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="${MACBAR_SCRIPT:-$here/../scripts/humanos-update-check}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# expect <name> <jq filter> <expected string> <json>
expect() {
  local got
  got=$(jq -r "$2" <<<"$4" 2>/dev/null)
  if [[ $got == "$3" ]]; then
    ok "$1"
  else
    no "$1 (got '$got', want '$3')"
  fi
}

expect_file_absent() {
  if [[ -e $2 ]]; then no "$1 (file exists)"; else ok "$1"; fi
}

# ------------------------------------------------------------------ stubs
stub_bin="$tmp/stub-bin"
mkdir -p "$stub_bin"

# nm-online: $MACBAR_STUB_ONLINE (0 = online, 1 = offline)
cat >"$stub_bin/nm-online" <<'EOF'
#!/usr/bin/env bash
exit "${MACBAR_STUB_ONLINE:-0}"
EOF
cat >"$stub_bin/omarchy-pkg-aur-accessible" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# checkupdates: writes $MACBAR_STUB_CHECKUPDATES_BODY to stdout, exits
# $MACBAR_STUB_CHECKUPDATES_RC.
cat >"$stub_bin/checkupdates" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MACBAR_STUB_CHECKUPDATES_BODY:-}"
exit "${MACBAR_STUB_CHECKUPDATES_RC:-0}"
EOF

# yay: stdout from $MACBAR_STUB_YAY_BODY, stderr from $MACBAR_STUB_YAY_ERR.
cat >"$stub_bin/yay" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MACBAR_STUB_YAY_BODY:-}"
printf '%s\n' "${MACBAR_STUB_YAY_ERR:-}" >&2
exit "${MACBAR_STUB_YAY_RC:-0}"
EOF

# flatpak: stdout from $MACBAR_STUB_FLATPAK_BODY.
cat >"$stub_bin/flatpak" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MACBAR_STUB_FLATPAK_BODY:-}"
exit "${MACBAR_STUB_FLATPAK_RC:-0}"
EOF

chmod +x "$stub_bin"/*

run_stub() { env -i \
  PATH="$stub_bin:$PATH" \
  HOME="$HOME" \
  XDG_CACHE_HOME="$1" \
  MACBAR_STUB_ONLINE="${2:-0}" \
  MACBAR_STUB_CHECKUPDATES_RC="${3:-2}" \
  MACBAR_STUB_CHECKUPDATES_BODY="${4:-}" \
  MACBAR_STUB_YAY_RC="${5:-1}" \
  MACBAR_STUB_YAY_BODY="${6:-}" \
  MACBAR_STUB_YAY_ERR="${7:-}" \
  MACBAR_STUB_FLATPAK_RC="${8:-0}" \
  MACBAR_STUB_FLATPAK_BODY="${9:-}" \
  "$script"; }

# ---------------------------------------------------------------------------
# 1. offline (no network namespace route): degraded, no state, cache untouched
echo "--- 1. offline run ---"
offline_cache="$tmp/offline"
mkdir -p "$offline_cache"
out=$(unshare -rn env XDG_CACHE_HOME="$offline_cache" HOME="$HOME" "$script" 2>/dev/null)
rc=$?
if (( rc == 0 )); then ok "offline: exit 0"; else no "offline: exit 0 (rc=$rc)"; fi
expect "offline: degraded=true" '.degraded | tostring' 'true' "$out"
expect "offline: no state" 'if .state then "has" else "none" end' 'none' "$out"
expect_file_absent "offline: cache not written" "$offline_cache/omarchy/humanos-update-cache.json"
expect "offline: sources reported" '.sources | length | tostring' '4' "$out"

# ---------------------------------------------------------------------------
# 2. offline with a populated cache: state preserved, cache not rewritten
echo "--- 2. degraded keeps previous state ---"
keep_cache="$tmp/keep"
mkdir -p "$keep_cache/omarchy"
prior='{"state":"updates","checkedAt":"2026-11-13T10:00:00+03:00","counts":{"extras":4},"packages":{},"omarchy":{"available":false,"from":"","to":""}}'
printf '%s\n' "$prior" >"$keep_cache/omarchy/humanos-update-cache.json"
before=$(stat -c '%Y %s' "$keep_cache/omarchy/humanos-update-cache.json")
out=$(unshare -rn env XDG_CACHE_HOME="$keep_cache" HOME="$HOME" "$script" 2>/dev/null)
after=$(stat -c '%Y %s' "$keep_cache/omarchy/humanos-update-cache.json")
expect "keep: degraded=true" '.degraded | tostring' 'true' "$out"
expect "keep: state=updates from cache" '.state' 'updates' "$out"
expect "keep: cache still holds the old count" '.counts.extras | tostring' '4' "$(cat "$keep_cache/omarchy/humanos-update-cache.json")"
if [[ $before == "$after" ]]; then ok "keep: cache mtime unchanged"; else no "keep: cache mtime unchanged"; fi

# ---------------------------------------------------------------------------
# 3. stubs: every network source fails -> degraded, sources say fail
echo "--- 3. all sources fail ---"
out=$(run_stub "$tmp/s3" 0 1 "" 1 "" "error: failed to connect" 1 "")
expect "s3: degraded=true" '.degraded | tostring' 'true' "$out"
expect "s3: repo=fail" '.sources.repo' 'fail' "$out"
expect "s3: aur=fail" '.sources.aur' 'fail' "$out"
expect "s3: flatpak=fail" '.sources.flatpak' 'fail' "$out"

# ---------------------------------------------------------------------------
# 4. stubs: checkupdates rc=2 is "nothing to do"
echo "--- 4. checkupdates rc=2 ---"
out=$(run_stub "$tmp/s4" 0 2 "" 1 "" "" 0 "")
expect "s4: degraded=false" '.degraded | tostring' 'false' "$out"
expect "s4: repo=ok" '.sources.repo' 'ok' "$out"
expect "s4: state=clean" '.state' 'clean' "$out"
if [[ -s $tmp/s4/omarchy/humanos-update-cache.json ]]; then ok "s4: cache written"; else no "s4: cache written"; fi

# ---------------------------------------------------------------------------
# 5. stubs: checkupdates rc=0 with an omarchy line
echo "--- 5. omarchy line from checkupdates ---"
out=$(run_stub "$tmp/s5" 0 0 "omarchy 1.7-1 -> 1.7-2" 1 "" "" 0 "")
expect "s5: omarchy.available=true" '.omarchy.available | tostring' 'true' "$out"
expect "s5: omarchy.to=1.7-2" '.omarchy.to' '1.7-2' "$out"
expect "s5: state=updates" '.state' 'updates' "$out"

# ---------------------------------------------------------------------------
# 6. stubs: flatpak parsing
echo "--- 6. flatpak ---"
fp_body=$'flathub\torg.gimp.GIMP\t\tstable\tx86_64\nflathub\torg.gimp.GIMP\t\tstable\taarch64\nflathub\torg.kde.krita\t\tstable\tx86_64'
out=$(run_stub "$tmp/s6" 0 2 "" 1 "" "" 0 "$fp_body")
expect "s6: flatpak=ok" '.sources.flatpak' 'ok' "$out"
expect "s6: flatpak count deduped" '.counts.flatpak | tostring' '2' "$out"

# ---------------------------------------------------------------------------
# 7. stubs: yay quiet negative is "ok"
echo "--- 7. yay empty negative ---"
out=$(run_stub "$tmp/s7" 0 2 "" 1 "" "" 0 "")
expect "s7: aur=ok" '.sources.aur' 'ok' "$out"
expect "s7: aur count 0" '.counts.aur | tostring' '0' "$out"

# ---------------------------------------------------------------------------
# 8. stubs: yay with stderr is a failure, not a negative
echo "--- 8. yay stderr ---"
out=$(run_stub "$tmp/s8" 0 2 "" 1 "" "error: failed to connect to aur" 0 "")
expect "s8: aur=fail" '.sources.aur' 'fail' "$out"
expect "s8: degraded=true" '.degraded | tostring' 'true' "$out"

# ---------------------------------------------------------------------------
# 9. stubs: no network at all -> sources fail fast, nothing is written
echo "--- 9. gate closed ---"
out=$(run_stub "$tmp/s9" 1 1 "" 1 "" "" 1 "")
expect "s9: degraded=true" '.degraded | tostring' 'true' "$out"
expect "s9: repo=fail" '.sources.repo' 'fail' "$out"
expect_file_absent "s9: no cache" "$tmp/s9/omarchy/humanos-update-cache.json"

# ---------------------------------------------------------------------------
# 10. metadata present on a good run
echo "--- 10. metadata ---"
out=$(run_stub "$tmp/s10" 0 2 "" 1 "" "" 0 "")
expect "s10: checkedAt ISO" '.checkedAt | test("^20[0-9-]+T") | tostring' 'true' "$out"
expect "s10: durationMs number" '.durationMs | type' 'number' "$out"

# ---------------------------------------------------------------------------
# 11. real online run (optional)
if [[ ${RUN_ONLINE:-0} == 1 ]]; then
  echo "--- 11. online run ---"
  online_cache="$tmp/online"
  start=$(date +%s)
  out=$(env XDG_CACHE_HOME="$online_cache" HOME="$HOME" "$script" 2>/dev/null)
  dur=$(( $(date +%s) - start ))
  expect "online: degraded=false" '.degraded | tostring' 'false' "$out"
  expect "online: state valid" '.state | IN("clean","updates","stale") | tostring' 'true' "$out"
  if [[ -s $online_cache/omarchy/humanos-update-cache.json ]]; then ok "online: cache written"; else no "online: cache written"; fi
  if (( dur < 120 )); then ok "online: ran under 120s (${dur}s)"; else no "online: ran under 120s (${dur}s)"; fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
