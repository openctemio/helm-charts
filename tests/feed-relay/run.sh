#!/usr/bin/env bash
# Render checks for the feed relay toggles: the sensor-enrollment Job passes
# -feed-relay for new installs (feedRelay.newInstallRelay), the sensor renders
# SENSOR_FEED_RELAY=0 when sensor.feedRelay.enabled=false, and extra origins
# reach SENSOR_FEED_RELAY_ORIGINS and the signer's SIGNER_FEED_ORIGINS.
# Usage: tests/feed-relay/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

render() { helm template t "$chart" --set api.appEnv=development --set sensor.enabled=true --set sensor.allowInsecureHTTP=true "$@" 2>&1; }
inst=(--set sensor.enrollment=instance --set sensor.sandbox.network=required --set sensor.localPolicy.enabled=true)

expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
must_fail() {
  local desc="$1" msg="$2" out
  shift 2
  if out="$(render "$@")"; then fail "$desc (render succeeded)"; else expect "$desc" "$msg" "$out"; fi
}

job=(-s templates/sensor-enrollment.yaml)
dep=(-s templates/sensor-deployment.yaml)
api=(-s templates/api-deployment.yaml)

# 1. Defaults: the Job passes -feed-relay, the sensor keeps its own default.
out="$(render "${inst[@]}" "${job[@]}")"
expect "default: Job passes -feed-relay" '- "-feed-relay"' "$out"
out="$(render "${inst[@]}" "${dep[@]}")"
reject "default: SENSOR_FEED_RELAY unset (sensor default)" "name: SENSOR_FEED_RELAY" "$out"

# 2. feedRelay.newInstallRelay=false: no flag.
out="$(render "${inst[@]}" --set feedRelay.newInstallRelay=false "${job[@]}")"
reject "newInstallRelay=false: no -feed-relay" '-feed-relay' "$out"
expect "newInstallRelay=false: Job still registers the token" '- "sensor-token"' "$out"

# 3. sensor.feedRelay.enabled=false: SENSOR_FEED_RELAY=0 and no flag
#    (a sensor that never relays cannot be the relay).
out="$(render "${inst[@]}" --set sensor.feedRelay.enabled=false "${dep[@]}")"
if grep -A1 'name: SENSOR_FEED_RELAY$' <<<"$out" | grep -q 'value: "0"'; then pass "enabled=false: SENSOR_FEED_RELAY=0"; else fail "enabled=false: SENSOR_FEED_RELAY=0"; fi
out="$(render "${inst[@]}" --set sensor.feedRelay.enabled=false "${job[@]}")"
reject "enabled=false: no -feed-relay" '-feed-relay' "$out"

# 4. Origins reach the sensor and the signer; off drops both.
orig=(--set 'sensor.feedRelay.origins[0]=https://mirror.example.com' --set 'sensor.feedRelay.origins[1]=https://m2.example.com:8443')
out="$(render "${inst[@]}" "${orig[@]}" "${dep[@]}")"
if grep -A1 'name: SENSOR_FEED_RELAY_ORIGINS' <<<"$out" | grep -q 'value: "https://mirror.example.com,https://m2.example.com:8443"'; then pass "origins: sensor env"; else fail "origins: sensor env"; fi
out="$(render "${inst[@]}" "${orig[@]}" "${api[@]}")"
if grep -A1 'name: SIGNER_FEED_ORIGINS' <<<"$out" | grep -q 'value: "https://mirror.example.com,https://m2.example.com:8443"'; then pass "origins: signer allowlist"; else fail "origins: signer allowlist"; fi
out="$(render "${inst[@]}" "${dep[@]}")"
reject "no origins: no SENSOR_FEED_RELAY_ORIGINS" "SENSOR_FEED_RELAY_ORIGINS" "$out"
out="$(render "${inst[@]}" "${api[@]}")"
reject "no origins: no SIGNER_FEED_ORIGINS" "SIGNER_FEED_ORIGINS" "$out"
out="$(render "${inst[@]}" "${orig[@]}" --set sensor.feedRelay.enabled=false "${api[@]}")"
reject "relay off: origins not added to the signer" "SIGNER_FEED_ORIGINS" "$out"

# 5. Refusals.
must_fail "http origin" "is not an https origin" "${inst[@]}" --set 'sensor.feedRelay.origins[0]=http://mirror.example.com'
must_fail "origin with a path" "is not an https origin" "${inst[@]}" --set 'sensor.feedRelay.origins[0]=https://mirror.example.com/feeds'
must_fail "comma inside one origin" "is not an https origin" "${inst[@]}" --set 'sensor.feedRelay.origins[0]=https://a.example.com\,https://b.example.com'
must_fail "signer allowlist set twice" "SIGNER_FEED_ORIGINS is set in api.signer.extraEnv" "${inst[@]}" "${orig[@]}" \
  --set 'api.signer.extraEnv[0].name=SIGNER_FEED_ORIGINS' --set 'api.signer.extraEnv[0].value=https://x.example.com'

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all feed-relay checks passed"
