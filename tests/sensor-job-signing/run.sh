#!/usr/bin/env bash
# Render checks for the bundled sensor's job-signing pin (sensor.jobSigning):
# the signer's own key exported to a ConfigMap by a container that alone
# holds a Kubernetes token limited to that ConfigMap; operator pins from
# values; the production refusal without the offline root.
# Usage: tests/sensor-job-signing/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
must_fail() { # description message helm-args...
  local d="$1" m="$2" out; shift 2
  if out="$(helm template t "$chart" "$@" 2>&1)"; then fail "$d (render succeeded)"; else expect "$d" "$m" "$out"; fi
}

dev=(--set api.appEnv=development --set sensor.enabled=true --set sensor.allowInsecureHTTP=true)
root="SHA256:$(printf 'a%.0s' {1..64})"
key="$(printf 'A%.0s' {1..43})="
# A section of the render: the document whose Source is the given template.
doc() { awk -v t="# Source: openctem/templates/$1" '/^---/{p=0} $0==t{p=1} p' <<<"$2"; }
# The exporter container of the API pod.
exporter() { awk '/^        - name: signer-pub-exporter$/{p=1;print;next} p&&/^        - name: /{p=0} p' <<<"$1"; }
# Every other container of the API pod.
others() { awk '/^        - name: signer-pub-exporter$/{p=1;next} p&&/^        - name: /{p=0} !p' <<<"$1"; }

# 1. Default with the sensor (dev): the chart signer's key is pinned.
out="$(helm template t "$chart" "${dev[@]}" 2>&1)"
api="$(doc api-deployment.yaml "$out")"
dep="$(doc sensor-deployment.yaml "$out")"
js="$(doc sensor-job-signing.yaml "$out")"
expect "signer publishes its public key" "name: SIGNER_PUBLISH_DIR" "$api"
expect "exporter container in the API pod" "name: signer-pub-exporter" "$api"
expect "API pod keeps automountServiceAccountToken false" "automountServiceAccountToken: false" "$api"
ex="$(exporter "$api")"
expect "exporter mounts the projected token" "mountPath: /var/run/secrets/openctem-exporter" "$ex"
expect "exporter reads the publish volume read-only" "readOnly: true" "$ex"
expect "exporter checks the key shape before sending" '${#k}' "$ex"
expect "exporter: no privilege escalation" "allowPrivilegeEscalation: false" "$ex"
expect "exporter: read-only root filesystem" "readOnlyRootFilesystem: true" "$ex"
rest="$(others "$api")"
reject "no other API pod container mounts the token" "openctem-exporter" "$rest"
if grep -B2 -A2 'mountPath: /run/openctem-signer-pub' <<<"$rest" | grep -q 'name: signer-pub'; then
  # Only the signer mounts it writable: the API container is checked below.
  pass "signer mounts the publish volume"
else
  fail "signer mounts the publish volume"
fi
apic="$(awk '/^        - name: api$/{p=1;print;next} p&&/^        - name: /{p=0} p' <<<"$api")"
reject "API container does not mount the publish volume" "signer-pub" "$apic"
reject "API container does not mount the token" "openctem-exporter" "$apic"
expect "token is short-lived" "expirationSeconds: 3600" "$api"
expect "empty ConfigMap rendered for the key" "name: t-openctem-api-signer-pub" "$js"
reject "the chart owns no key data" "signer.pub:" "$js"
expect "Role limited to that ConfigMap" 'resourceNames: ["t-openctem-api-signer-pub"]' "$js"
expect "Role verbs get and patch only" 'verbs: ["get", "patch"]' "$js"
reject "Role cannot create" '"create"' "$js"
reject "Role cannot list" '"list"' "$js"
reject "no Secret access" "secrets" "$js"
expect "bound to the API service account" "name: t-openctem-api" "$js"
expect "sensor pins from a file" "name: SENSOR_JOB_SIGNING_KEYS_FILE" "$dep"
expect "sensor pin path" "value: /etc/openctem/job-signing/signer.pub" "$dep"
expect "sensor mounts the exported ConfigMap" "name: t-openctem-api-signer-pub" "$dep"
expect "sensor needs the key (non-optional item)" "key: signer.pub" "$dep"
reject "sensor ConfigMap volume not optional" "optional: true" "$dep"
if grep -B1 -A1 'mountPath: /etc/openctem/job-signing' <<<"$dep" | grep -q 'readOnly: true'; then
  pass "pin mounted read-only"
else
  fail "pin mounted read-only"
fi

# 2. No sensor, or no pin from the signer: nothing exported.
out="$(helm template t "$chart" --set api.appEnv=development 2>&1)"
reject "no sensor: no exporter" "signer-pub-exporter" "$out"
reject "no sensor: no publish dir" "SIGNER_PUBLISH_DIR" "$out"
reject "no sensor: no Role" "kind: Role" "$out"
out="$(helm template t "$chart" "${dev[@]}" --set sensor.jobSigning.fromSigner=false 2>&1)"
reject "fromSigner=false: no exporter" "signer-pub-exporter" "$out"
reject "fromSigner=false: no pin" "SENSOR_JOB_SIGNING" "$out"
out="$(helm template t "$chart" "${dev[@]}" --set api.signer.enabled=false 2>&1)"
reject "no chart signer: no exporter" "signer-pub-exporter" "$out"

# 3. Operator pins from values: rendered, exclusive, no exporter.
out="$(helm template t "$chart" "${dev[@]}" --set api.signer.keyset.existingSecret=ks --set "sensor.jobSigning.root=$root" 2>&1)"
dep="$(doc sensor-deployment.yaml "$out")"
js="$(doc sensor-job-signing.yaml "$out")"
expect "root pin file" "name: SENSOR_JOB_SIGNING_ROOT_FILE" "$dep"
expect "root in the ConfigMap" "root: \"$root\"" "$js"
expect "root ConfigMap name" "name: t-openctem-sensor-job-signing" "$dep"
expect "a changed pin rolls the sensor" "checksum/job-signing:" "$dep"
reject "root: no exporter" "signer-pub-exporter" "$out"
reject "root: no Role" "kind: Role" "$out"
out="$(helm template t "$chart" "${dev[@]}" --set "sensor.jobSigning.keys={$key,$root}" 2>&1)"
expect "keys pin file" "value: /etc/openctem/job-signing/keys" "$(doc sensor-deployment.yaml "$out")"
expect "keys in the ConfigMap" "keys: \"$key\\n$root\"" "$(doc sensor-job-signing.yaml "$out")"

# 4. Refusals.
must_fail "malformed root" "jobSigning" "${dev[@]}" --set sensor.jobSigning.root=SHA256:abc
must_fail "malformed key" "jobSigning" "${dev[@]}" --set "sensor.jobSigning.keys={nope}"
must_fail "root without a key set the API serves" "api.signer.keyset.existingSecret" "${dev[@]}" --set "sensor.jobSigning.root=$root"
must_fail "production sensor without the offline root" "needs sensor.jobSigning.root" \
  -f "$chart/values-production.yaml" --set sensor.enabled=true --set sensor.apiUrl=https://openctem.example.com
if helm template t "$chart" -f "$chart/values-production.yaml" --set sensor.enabled=true --set sensor.apiUrl=https://openctem.example.com \
  --set "sensor.jobSigning.root=$root" --set api.signer.keyset.existingSecret=ks >/dev/null 2>&1; then
  pass "production sensor with the offline root renders"
else
  fail "production sensor with the offline root renders: $(helm template t "$chart" -f "$chart/values-production.yaml" --set sensor.enabled=true --set sensor.apiUrl=https://openctem.example.com --set "sensor.jobSigning.root=$root" --set api.signer.keyset.existingSecret=ks 2>&1 | tail -3)"
fi

if [[ $fails -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all sensor job-signing checks passed"
