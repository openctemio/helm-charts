#!/usr/bin/env bash
# Render checks for the bundled sensor's pairing code, the in-cluster http
# refusal and keeping the identity volume on uninstall.
# Usage: tests/sensor-pairing/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

base=(--set api.appEnv=development --set sensor.enabled=true)
render() { helm template t "$chart" "${base[@]}" "$@" 2>&1; }

expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
must_fail() { # must_fail <description> <message pattern> <helm args...>
  local desc="$1" msg="$2" out
  shift 2
  if out="$(render "$@")"; then fail "$desc (render succeeded)"; else expect "$desc" "$msg" "$out"; fi
}

http=(--set sensor.allowInsecureHTTP=true)
dep=(-s templates/sensor-deployment.yaml)

# 1. The default in-cluster http URL is refused until acknowledged.
must_fail "default in-cluster http URL fails the render" "plain http to a host that is not loopback"
must_fail "an explicit http URL fails too" "http://sensor-api.example.com" --set sensor.apiUrl=http://sensor-api.example.com
out="$(render --set sensor.apiUrl=https://api.example.com "${dep[@]}")"
expect "https URL renders" 'value: "https://api.example.com"' "$out"
reject "https URL: no insecure flag" "SENSOR_ALLOW_INSECURE_HTTP" "$out"
out="$(render --set sensor.apiUrl=http://127.0.0.1:8080 "${dep[@]}")"
expect "loopback http renders" 'value: "http://127.0.0.1:8080"' "$out"
out="$(render "${http[@]}" "${dep[@]}")"
expect "allowInsecureHTTP sets SENSOR_ALLOW_INSECURE_HTTP" "name: SENSOR_ALLOW_INSECURE_HTTP" "$out"

# 2. Pairing code.
reject "no pairing code by default" "SENSOR_PAIRING_CODE" "$out"
out="$(render "${http[@]}" --set sensor.pairingCode=ABCD-EFGH "${dep[@]}")"
expect "pairingCode renders SENSOR_PAIRING_CODE" 'name: SENSOR_PAIRING_CODE' "$out"
expect "pairingCode value" 'value: "ABCD-EFGH"' "$out"
out="$(render "${http[@]}" --set sensor.pairingCodeExistingSecret=my-code "${dep[@]}")"
expect "existing Secret: secretKeyRef" 'name: "my-code"' "$out"
expect "existing Secret: default key" 'key: "pairing-code"' "$out"
out="$(render "${http[@]}" --set sensor.pairingCodeExistingSecret=my-code --set sensor.pairingCodeExistingSecretKey=code "${dep[@]}")"
expect "existing Secret: custom key" 'key: "code"' "$out"
must_fail "code and Secret together are refused" "Set only one of" "${http[@]}" --set sensor.pairingCode=X --set sensor.pairingCodeExistingSecret=y
must_fail "code with an API key is refused" "applies only to sensor.enrollment=pairing" "${http[@]}" --set sensor.pairingCode=X --set sensor.apiKey=k
must_fail "code with enrollment=instance is refused" "applies only to sensor.enrollment=pairing" "${http[@]}" --set sensor.pairingCode=X --set sensor.enrollment=instance

# 3. Keep the identity volume on uninstall.
out="$(render "${http[@]}" -s templates/sensor-data-pvc.yaml)"
expect "data PVC kept on uninstall by default" "helm.sh/resource-policy: keep" "$out"
out="$(render "${http[@]}" --set sensor.persistence.keepOnUninstall=false -s templates/sensor-data-pvc.yaml)"
reject "keepOnUninstall=false: no keep annotation" "helm.sh/resource-policy" "$out"
out="$(render "${http[@]}" --set sensor.storageLayout=split -s templates/sensor-state-pvc.yaml)"
expect "state PVC kept on uninstall by default" "helm.sh/resource-policy: keep" "$out"
out="$(render "${http[@]}" --set sensor.storageLayout=split --set sensor.persistence.keepOnUninstall=false -s templates/sensor-state-pvc.yaml)"
reject "split, keepOnUninstall=false: no keep annotation" "helm.sh/resource-policy" "$out"
out="$(render "${http[@]}" --set sensor.storageLayout=split -s templates/sensor-content-pvc.yaml)"
reject "the disposable content cache is not kept" "helm.sh/resource-policy" "$out"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all sensor pairing checks passed"
