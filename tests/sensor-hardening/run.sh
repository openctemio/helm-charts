#!/usr/bin/env bash
# Render checks for the bundled sensor's hardening defaults and the
# sensor-local policy (OpenCTEM RFC-040 §5.7, §5.10).
# Usage: tests/sensor-hardening/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

base=(--set api.appEnv=development --set sensor.enabled=true --set sensor.apiKey=rda_test)
render() { helm template t "$chart" "${base[@]}" -s templates/sensor-deployment.yaml "$@" 2>&1; }
renderAll() { helm template t "$chart" "${base[@]}" "$@" 2>&1; }

# 1. Hardened by default.
out="$(render)"
expect "runAsNonRoot" "runAsNonRoot: true" "$out"
expect "runAsUser 999 (the default image's user)" "runAsUser: 999" "$out"
expect "fsGroup 999" "fsGroup: 999" "$out"
expect "fsGroup only on a new volume (identity stays 0600)" "fsGroupChangePolicy: OnRootMismatch" "$out"
expect "seccomp RuntimeDefault" "type: RuntimeDefault" "$out"
expect "no privilege escalation" "allowPrivilegeEscalation: false" "$out"
expect "read-only root filesystem" "readOnlyRootFilesystem: true" "$out"
expect "drop ALL capabilities" "- ALL" "$out"
reject "no NET_RAW by default" "NET_RAW" "$out"
for d in /tmp /var/lib/openctem/state /var/lib/openctem/content /var/lib/openctem/outbox; do
  expect "writable $d" "mountPath: $d" "$out"
done
# The image's home holds the baked nuclei-templates release: never hidden.
reject "home directory not mounted over" "mountPath: /home/openctem" "$out"
expect "tool configuration under /tmp" "value: /tmp/.config" "$out"
expect "tool cache under /tmp" "value: /tmp/.cache" "$out"
# An fsGroup set without a policy (an older values file) still gets OnRootMismatch;
# an explicit policy is kept.
out="$(render --set sensor.podSecurityContext.fsGroupChangePolicy=null)"
expect "policy added when unset" "fsGroupChangePolicy: OnRootMismatch" "$out"
out="$(render --set sensor.podSecurityContext.fsGroupChangePolicy=Always)"
expect "explicit policy kept" "fsGroupChangePolicy: Always" "$out"
out="$(render)"
reject "no local policy by default" "SENSOR_LOCAL_POLICY" "$out"
out="$(renderAll)"
reject "no policy ConfigMap by default" "sensor-policy.yaml:" "$out"

# 2. netRaw adds NET_RAW and keeps drop ALL.
out="$(render --set sensor.netRaw=true)"
expect "netRaw: NET_RAW added" "- NET_RAW" "$out"
expect "netRaw: still drops ALL" "- ALL" "$out"

# 3. Overridable: the single-tool images' uid, and a writable root.
out="$(render --set sensor.podSecurityContext.runAsUser=1001 --set sensor.securityContext.readOnlyRootFilesystem=false)"
expect "runAsUser override" "runAsUser: 1001" "$out"
expect "readOnlyRootFilesystem override" "readOnlyRootFilesystem: false" "$out"

# 4. The local policy from values: ConfigMap, env, read-only 0444 mount,
#    and a checksum that rolls the pod on change.
out="$(renderAll --set sensor.localPolicy.enabled=true)"
expect "policy ConfigMap" "name: t-openctem-sensor-policy" "$out"
expect "policy content" "apiVersion: openctem.io/sensor-policy/v1" "$out"
expect "policy keeps custom templates off" "allow_custom_templates: false" "$out"
expect "policy keeps interactsh off" "allow_interactsh: false" "$out"
expect "SENSOR_LOCAL_POLICY env" "value: /etc/openctem/sensor-policy.yaml" "$out"
expect "read-only mount" "readOnly: true" "$out"
expect "mode 0444" "defaultMode: 0444" "$out"
expect "checksum annotation" "checksum/local-policy:" "$out"
a="$(renderAll --set sensor.localPolicy.enabled=true | grep checksum/local-policy)"
b="$(renderAll --set sensor.localPolicy.enabled=true --set-string 'sensor.localPolicy.policy=apiVersion: openctem.io/sensor-policy/v1
kill_switch: true
' | grep checksum/local-policy)"
if [[ "$a" != "$b" ]]; then pass "a changed policy changes the checksum"; else fail "a changed policy changes the checksum"; fi

# 5. An existing ConfigMap: no ConfigMap rendered, the mount names it.
out="$(renderAll --set sensor.localPolicy.enabled=true --set sensor.localPolicy.existingConfigMap=owner-policy --set sensor.localPolicy.existingConfigMapKey=policy.yaml)"
expect "existing ConfigMap mounted" "name: owner-policy" "$out"
expect "existing ConfigMap key" "key: policy.yaml" "$out"
reject "no chart ConfigMap with existingConfigMap" "name: t-openctem-sensor-policy" "$out"

# 6. Not a policy document: the render fails.
if out="$(renderAll --set sensor.localPolicy.enabled=true --set-string sensor.localPolicy.policy=foo)"; then
  fail "a non-policy document fails the render"
else
  expect "a non-policy document fails the render" "sensor.localPolicy.policy must be a sensor-local policy document" "$out"
fi

# 7. Kill switch file and extra volumes.
out="$(render --set sensor.localPolicy.killSwitchFile=/run/owner/STOP --set 'sensor.extraVolumes[0].name=owner' --set 'sensor.extraVolumes[0].hostPath.path=/etc/openctem-owner' --set 'sensor.extraVolumeMounts[0].name=owner' --set 'sensor.extraVolumeMounts[0].mountPath=/run/owner' --set 'sensor.extraVolumeMounts[0].readOnly=true')"
expect "kill switch env" "value: \"/run/owner/STOP\"" "$out"
expect "extra volume" "path: /etc/openctem-owner" "$out"
expect "extra mount" "mountPath: /run/owner" "$out"

# 8. Per-task network confinement (RFC-060) and the sensor seccomp profile.
out="$(render)"
expect "confinement auto by default" 'value: "auto"' "$out"
reject "no Localhost profile by default" "type: Localhost" "$out"
reject "no installer by default" "sensor-seccomp" "$(renderAll)"
out="$(renderAll --set sensor.sandbox.seccompProfile=openctem --set sensor.sandbox.network=required)"
expect "Localhost profile" "type: Localhost" "$out"
expect "profile named by digest" "localhostProfile: openctem/sensor-" "$out"
expect "confinement required" 'value: "required"' "$out"
expect "installer DaemonSet" "kind: DaemonSet" "$out"
expect "installer writes only the openctem seccomp dir" 'path: "/var/lib/kubelet/seccomp/openctem"' "$out"
expect "installer drops capabilities" 'drop: ["ALL"]' "$out"
expect "installer has no service account token" "automountServiceAccountToken: false" "$out"
reject "installer never privileged" "privileged: true" "$out"
file="$(grep -o 'openctem/sensor-[0-9a-f]*\.json' <<<"$out" | head -1)"
expect "installer writes the file the Deployment names" "/host/$(basename "$file")" "$out"
out="$(renderAll --set sensor.sandbox.seccompProfile=openctem --set sensor.sandbox.installProfile=false)"
reject "installProfile=false: no installer" "kind: DaemonSet" "$out"
expect "installProfile=false: still Localhost" "type: Localhost" "$out"
if out="$(render --set sensor.sandbox.network=required)"; then
  fail "required under the runtime default profile fails the render"
else
  expect "required under the runtime default profile fails the render" "cannot work under the runtime's default seccomp profile" "$out"
fi
if out="$(render --set sensor.podSecurityContext.seccompProfile.type=Unconfined)"; then
  fail "Unconfined seccomp fails the render"
else
  expect "Unconfined seccomp fails the render" "Unconfined is refused" "$out"
fi
if out="$(render --set sensor.sandbox.network=maybe)"; then
  fail "unknown sandbox.network fails the render"
else
  expect "unknown sandbox.network fails the render" "must be auto, required or off" "$out"
fi

if [[ $fails -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all sensor hardening checks passed"
