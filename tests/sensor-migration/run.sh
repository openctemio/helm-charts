#!/usr/bin/env bash
# Render checks for the agent -> sensor values migration (chart 0.5.0).
# Usage: tests/sensor-migration/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# Every check renders a scratch copy of the chart (set up below), never the
# checkout. helm template does not print NOTES.txt, so the copy also renders
# it into a ConfigMap the checks can grep.
render() { helm template t "$tmp/chart" "$@" 2>&1; }

expect() { # expect <description> <pattern> <output>
  if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
reject() { # reject <description> <pattern> <output>
  if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$chart" "$tmp/chart"
cat > "$tmp/chart/templates/zz-notes.yaml" <<'EOT'
apiVersion: v1
kind: ConfigMap
metadata:
  name: zz-rendered-notes
data:
  notes: |
{{ include (print $.Template.BasePath "/NOTES.txt") . | indent 4 }}
EOT
cat > "$tmp/chart/templates/zz-sensor-defaults-check.yaml" <<'EOT'
{{- if .Values.zzCheckSensorDefaults }}
{{- $want := .Values.sensor | toJson -}}
{{- $got := include "openctem.sensorDefaults" . | fromYaml | toJson -}}
{{- if ne $want $got }}
{{- fail (printf "openctem.sensorDefaults drifted from values.yaml\n values.yaml: %s\n helper:      %s" $want $got) }}
{{- end }}
{{- end }}
EOT

# 1. The defaults copy in _helpers.tpl matches values.yaml (rendered with no
#    user values, so .Values.sensor is exactly the values.yaml block).
if out="$(render --set api.appEnv=development --set zzCheckSensorDefaults=true)"; then
  pass "openctem.sensorDefaults matches values.yaml"
else
  fail "openctem.sensorDefaults matches values.yaml: $out"
fi

# 2. Defaults: no sensor, no agent objects.
out="$(render --set api.appEnv=development)"
reject "default render has no sensor" "component: sensor" "$out"
reject "default render has no agent" "component: agent" "$out"

# 3. sensor.enabled=true (daemon mode, API key).
D=(--set api.appEnv=development --set sensor.enabled=true --set sensor.apiKey=rda_test)
out="$(render "${D[@]}")"
expect "sensor: Deployment" "name: t-openctem-sensor" "$out"
expect "sensor: component label" "app.kubernetes.io/component: sensor" "$out"
expect "sensor: image" 'image: "ghcr.io/openctemio/sensor:v0.6.3"' "$out"
expect "sensor: drain grace period" "terminationGracePeriodSeconds: 45" "$out"
expect "sensor: daemon" '"-daemon"' "$out"
expect "sensor: dispatched commands" '"-enable-commands"' "$out"
expect "sensor: tools" '"-tools=nuclei"' "$out"
expect "sensor: API_KEY" "name: API_KEY" "$out"
expect "sensor: chart Secret" "name: t-openctem-sensor-credentials" "$out"
expect "sensor: Secret key" 'api-key: "rda_test"' "$out"
reject "sensor: no -platform" '"-platform"' "$out"
reject "sensor: no BOOTSTRAP_TOKEN" "name: BOOTSTRAP_TOKEN" "$out"
expect "sensor: key auto-renew on with the state PVC" 'name: PLATFORM_KEY_AUTORENEW
              value: "true"' "$out"
expect "sensor: credentials in the state volume" '"-credentials=/var/lib/openctem/state/sensor-credentials.json"' "$out"
expect "sensor: SENSOR_STATE_DIR" 'name: SENSOR_STATE_DIR' "$out"
expect "sensor: state PVC" "name: t-openctem-sensor-state" "$out"
expect "sensor: state mounted" "mountPath: /var/lib/openctem/state" "$out"
expect "sensor: content PVC" "name: t-openctem-sensor-content" "$out"
expect "sensor: content PVC size" 'storage: "5Gi"' "$out"
expect "sensor: content mounted" "mountPath: /var/lib/openctem/content" "$out"
expect "sensor: Recreate with the PVCs" "type: Recreate" "$out"
expect "sensor: fsGroup for the PVCs" "fsGroup: 999" "$out"
expect "sensor: NOTES state" "Key auto-renewal: ON" "$out"
reject "sensor: no SENSOR_NAME" "name: SENSOR_NAME" "$out"
reject "sensor: private targets off by default" "name: SENSOR_ALLOW_PRIVATE_TARGETS" "$out"
reject "sensor: no AGENT_ env" "name: AGENT_" "$out"
reject "sensor: no httpsec opt-out" "OPENCTEM_SDK_HTTPSEC_ALLOW_PRIVATE" "$out"

out="$(render "${D[@]}" --set-string sensor.allowPrivateTargets=1 --set sensor.scanRoots=/scan:/work)"
expect "sensor: allowPrivateTargets=1" 'name: SENSOR_ALLOW_PRIVATE_TARGETS
              value: "1"' "$out"
expect "sensor: scanRoots" 'value: "/scan:/work"' "$out"

out="$(render "${D[@]}" --set sensor.existingSecret=octem-sensor --set sensor.existingSecretKey=key)"
expect "sensor: existingSecret" "name: octem-sensor" "$out"
reject "sensor: existingSecret, no chart Secret" "t-openctem-sensor-credentials" "$out"

# State and content volumes, key auto-renewal.
out="$(render "${D[@]}" --set sensor.state.persistence.enabled=false --set sensor.content.persistence.enabled=false --set sensor.content.emptyDirSizeLimit=3Gi)"
expect "sensor: no state PVC: auto-renew off" 'name: PLATFORM_KEY_AUTORENEW
              value: "false"' "$out"
reject "sensor: no state PVC object" "name: t-openctem-sensor-state" "$out"
reject "sensor: no content PVC object" "name: t-openctem-sensor-content" "$out"
expect "sensor: content emptyDir limit" "sizeLimit: 3Gi" "$out"
reject "sensor: no Recreate without PVCs" "type: Recreate" "$out"
expect "sensor: NOTES emptyDir state" "State is an emptyDir, so key auto-renewal is off" "$out"
out="$(render "${D[@]}" --set sensor.state.persistence.enabled=false --set sensor.keyAutoRenew=true)"
expect "sensor: keyAutoRenew=true forces it" 'name: PLATFORM_KEY_AUTORENEW
              value: "true"' "$out"
expect "sensor: NOTES warns about a lost key" "a renewed key is lost with the pod" "$out"
out="$(render "${D[@]}" --set sensor.keyAutoRenew=false)"
expect "sensor: keyAutoRenew=false turns it off" 'name: PLATFORM_KEY_AUTORENEW
              value: "false"' "$out"
out="$(render "${D[@]}" --set sensor.state.persistence.existingClaim=my-state --set sensor.content.persistence.existingClaim=my-content)"
expect "sensor: state existingClaim" "claimName: my-state" "$out"
expect "sensor: content existingClaim" "claimName: my-content" "$out"
reject "sensor: existingClaim, no state PVC object" "name: t-openctem-sensor-state" "$out"
if out="$(render "${D[@]}" --set sensor.keyAutoRenew=maybe)"; then
  fail "sensor: unknown keyAutoRenew must fail"
else
  expect "sensor: unknown keyAutoRenew fails" 'sensor.keyAutoRenew="maybe" is not recognised' "$out"
fi
if out="$(render "${D[@]}" --set sensor.replicaCount=2)"; then
  fail "sensor: 2 replicas with the state/content PVCs must fail"
else
  expect "sensor: 2 replicas with PVCs fails" "sensor.state.persistence and sensor.content.persistence need sensor.replicaCount=1" "$out"
fi
out="$(render "${D[@]}" --set sensor.replicaCount=2 --set sensor.state.persistence.enabled=false --set sensor.content.persistence.enabled=false)"
expect "sensor: 2 replicas without PVCs render" "replicas: 2" "$out"

# Platform mode (bootstrap token) was removed: no API serves it.
if out="$(render --set api.appEnv=development --set sensor.enabled=true --set sensor.mode=platform --set sensor.apiKey=rda_test)"; then
  fail "sensor: mode=platform must fail"
else
  expect "sensor: mode=platform fails with the reason" "sensor.mode=platform was removed in chart 0.9.0" "$out"
fi

if out="$(render --set api.appEnv=development --set sensor.enabled=true)"; then
  fail "sensor: daemon without an API key must fail"
else
  expect "sensor: daemon without an API key fails" "requires either sensor.apiKey or sensor.existingSecret" "$out"
fi
if out="$(render "${D[@]}" --set sensor.mode=agent)"; then
  fail "sensor: unknown mode must fail"
else
  expect "sensor: unknown mode fails" 'sensor.mode="agent" is not supported' "$out"
fi
if out="$(render "${D[@]}" --set sensor.allowPrivateTargets=true)"; then
  fail "sensor: allowPrivateTargets=true must fail"
else
  expect "sensor: allowPrivateTargets=true fails" 'sensor.allowPrivateTargets="true" is not recognised' "$out"
fi

# 4. An old values file with agent: (chart <= 0.4.x ran -platform, now removed).
if out="$(render -f "$here/legacy-agent-values.yaml")"; then
  fail "legacy: an agent: block without an API key must fail"
else
  expect "legacy: fails with what to set" 'That mode was removed in chart 0.9.0' "$out"
  reject "legacy: never prints the token" "test-bootstrap-token" "$out"
fi
if out="$(render -f "$here/legacy-existing-secret-only-values.yaml")"; then
  fail "legacy: agent.existingSecret alone must fail"
else
  expect "legacy existingSecret alone: fails" 'sensor.existingSecret may name the Secret agent.existingSecret used' "$out"
fi

out="$(render -f "$here/legacy-agent-with-key-values.yaml")"
expect "legacy: sensor Deployment" "name: t-openctem-sensor" "$out"
reject "legacy: no agent objects" "app.kubernetes.io/component: agent" "$out"
expect "legacy: sensor image (frozen agent image dropped)" 'image: "ghcr.io/openctemio/sensor:v0.6.3"' "$out"
expect "legacy: daemon" '"-daemon"' "$out"
reject "legacy: no -platform" '"-platform"' "$out"
reject "legacy: no BOOTSTRAP_TOKEN" "name: BOOTSTRAP_TOKEN" "$out"
expect "legacy: region mapped" 'value: "eu-west"' "$out"
expect "legacy: verbose mapped" '"-verbose"' "$out"
expect "legacy: keyAutoRenew mapped" 'name: PLATFORM_KEY_AUTORENEW
              value: "true"' "$out"
expect "legacy: resources mapped" "memory: 64Mi" "$out"
reject "legacy: private targets stay blocked" "name: SENSOR_ALLOW_PRIVATE_TARGETS" "$out"
reject "legacy: the bootstrap token is not rendered" "unused-bootstrap-token" "$out"
expect "legacy: NOTES deprecation" "Your values use the \`agent:\` block" "$out"
expect "legacy: NOTES dropped image" "agent.image.tag=v0.2.2-default" "$out"

out="$(render -f "$here/legacy-existing-secret-values.yaml")"
expect "legacy existingSecret: name kept" "name: my-agent-token" "$out"
expect "legacy existingSecret: key kept" "key: token" "$out"
reject "legacy existingSecret: no chart Secret" "t-openctem-sensor-credentials" "$out"
expect "legacy allowPrivateTargets=true -> 1" 'name: SENSOR_ALLOW_PRIVATE_TARGETS
              value: "1"' "$out"
expect "legacy allowPrivateTargets=true: NOTES" "private (RFC1918 / ULA) targets ARE allowed" "$out"

out="$(render -f "$here/legacy-mirror-values.yaml")"
expect "legacy mirror: repository and tag kept" 'image: "registry.example.com/openctemio/sensor:v0.3.0-default"' "$out"

out="$(render -f "$here/legacy-to-daemon-values.yaml")"
expect "legacy + sensor.apiKey: daemon mode" '"-daemon"' "$out"
expect "legacy + sensor.apiKey: API_KEY" "name: API_KEY" "$out"
expect "legacy + sensor.apiKey: region still mapped" 'value: "eu-west"' "$out"

out="$(render -f "$here/both-agree-values.yaml")"
expect "agent + sensor agreeing: renders" '"-tools=nuclei,trivy"' "$out"

# 5. agent + sensor conflicting.
if out="$(render -f "$here/conflict-values.yaml")"; then
  fail "conflict must fail"
else
  expect "conflict: message" "The values set both the legacy \`agent:\` block and \`sensor:\`, with different values" "$out"
  expect "conflict: names the key" 'agent.tools and sensor.tools' "$out"
  expect "conflict: names every key" 'agent.apiKey and sensor.apiKey' "$out"
  reject "conflict: never prints values (old token)" "old-token" "$out"
  reject "conflict: never prints values (new token)" "new-token" "$out"
fi

# 6. API settings renamed in api.extraEnv.
out="$(render -f "$here/api-env-values.yaml")"
expect "api env: AGENT_KEY_TTL -> SENSOR_KEY_TTL" "name: SENSOR_KEY_TTL" "$out"
reject "api env: no AGENT_ names left" "name: AGENT_" "$out"
expect "api env: others unchanged" "name: LOG_LEVEL" "$out"
if out="$(render -f "$here/api-env-conflict-values.yaml")"; then
  fail "api env conflict must fail"
else
  expect "api env conflict: message" "api.extraEnv sets both AGENT_KEY_TTL" "$out"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all sensor migration checks passed"
