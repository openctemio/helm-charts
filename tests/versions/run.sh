#!/usr/bin/env bash
# shellcheck disable=SC2015 # pass() never fails, so "a && pass || fail" is if/else here
# Tests for check-published.sh against local repositories (no network).
# Usage: tests/versions/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo() { # repo DIR TAG...: a git repository with these tags
  local d="$1"; shift
  git init -q "$d"
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  for t in "$@"; do git -C "$d" tag "$t"; done
}
repo "$tmp/platform" v0.8.0
repo "$tmp/sensor" v0.6.3

chart() { # chart APP SENSOR_TAG
  mkdir -p "$tmp/chart"
  printf 'apiVersion: v2\nname: openctem\nversion: 0.10.0\nappVersion: "%s"\n' "$1" >"$tmp/chart/Chart.yaml"
  printf 'api:\n  image:\n    tag: ""\nsensor:\n  enabled: false\n  image:\n    repository: ghcr.io/openctemio/sensor\n    tag: "%s"\n  other:\n    tag: nope\n' "$2" >"$tmp/chart/values.yaml"
}
run() { CHART_DIR="$tmp/chart" PLATFORM_REPO="$tmp/platform" SENSOR_REPO="$tmp/sensor" bash "$here/check-published.sh" 2>&1; }

chart v0.8.0 v0.6.3
out="$(run)" && pass "released tags: exit 0" || fail "released tags: exit 0"
grep -q "ok: appVersion (API, web, migrations images) v0.8.0 is released" <<<"$out" && pass "appVersion found" || fail "appVersion found: $out"
grep -q "ok: sensor.image.tag v0.6.3 is released" <<<"$out" && pass "sensor tag read from sensor.image.tag" || fail "sensor tag: $out"

chart v0.9.0 v0.6.3
out="$(run)" && pass "unreleased appVersion: warns, exit 0" || fail "unreleased appVersion: exit 0"
grep -q "::warning::appVersion (API, web, migrations images) v0.9.0 is not a released tag" <<<"$out" && pass "unreleased appVersion: warning" || fail "warning: $out"
if out="$(STRICT=1 run)"; then fail "STRICT: exit 1"; else pass "STRICT: exit 1"; fi
grep -q "::error::appVersion" <<<"$out" && pass "STRICT: error annotation" || fail "STRICT annotation: $out"

chart v0.8.0 v9.9.9
out="$(STRICT=1 run || true)"
grep -q "::error::sensor.image.tag v9.9.9 is not a released tag" <<<"$out" && pass "unreleased sensor tag" || fail "sensor: $out"

chart v0.8.0 v0.6.3
git -C "$tmp/sensor" tag v0.7.0
out="$(STRICT=1 run || true)"
grep -q "::error::sensor.image.tag v0.6.3 is not the newest sensor release v0.7.0" <<<"$out" && pass "an older sensor tag than the newest release" || fail "newest: $out"
chart v0.8.0 v0.7.0
out="$(STRICT=1 run)" && pass "the newest sensor tag: exit 0" || fail "newest tag: $out"

# The chart's seccomp profile must be that release's file.
mkdir -p "$tmp/sensor/docker/seccomp" "$tmp/chart/files/seccomp"
echo '{"defaultAction":"SCMP_ACT_ERRNO","v":2}' >"$tmp/sensor/docker/seccomp/sensor.json"
git -C "$tmp/sensor" add -A && git -C "$tmp/sensor" -c user.name=t -c user.email=t@example.invalid commit -q -m profile && git -C "$tmp/sensor" tag v0.7.1
chart v0.8.0 v0.7.1
mkdir -p "$tmp/chart/files/seccomp"
echo '{"defaultAction":"SCMP_ACT_ERRNO","v":1}' >"$tmp/chart/files/seccomp/openctem-sensor.json"
out="$(STRICT=1 run || true)"
grep -q "::error::files/seccomp/openctem-sensor.json differs" <<<"$out" && pass "a stale seccomp profile" || fail "profile: $out"
cp "$tmp/sensor/docker/seccomp/sensor.json" "$tmp/chart/files/seccomp/openctem-sensor.json"
out="$(STRICT=1 run)" && pass "the release's seccomp profile: exit 0" || fail "profile ok: $out"

# The real chart: its tags are read (network: skipped when offline).
if git ls-remote --exit-code https://github.com/openctemio/openctem.git HEAD >/dev/null 2>&1; then
  out="$(bash "$here/check-published.sh")" && pass "real chart: runs" || fail "real chart: $out"
fi

if [[ $fails -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all version checks passed"
