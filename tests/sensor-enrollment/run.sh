#!/usr/bin/env bash
# Render checks for sensor.enrollment (the bundled sensor as a shared sensor,
# api RFC-100 §7): the default stays pairing; instance renders the token
# Secret, the registering Job and the sensor's SENSOR_INSTANCE_ENROLLMENT_TOKEN;
# an existing Secret renders nothing secret; an API key is refused.
# Usage: tests/sensor-enrollment/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

render() { helm template t "$chart" --set api.appEnv=development --set sensor.enabled=true --set sensor.allowInsecureHTTP=true "$@" 2>&1; }
# A shared sensor needs the sandbox, network confinement and a local policy.
inst=(--set sensor.enrollment=instance --set sensor.sandbox.network=required --set sensor.localPolicy.enabled=true)

expect() { # expect <description> <pattern> <output>
  if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
reject() { # reject <description> <pattern> <output>
  if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}
must_fail() { # must_fail <description> <message pattern> <helm args...>
  local desc="$1" msg="$2" out
  shift 2
  if out="$(render "$@")"; then
    fail "$desc (render succeeded)"
  else
    expect "$desc" "$msg" "$out"
  fi
}

# 1. Default: pairing, no token, no Job.
out="$(render)"
reject "default: no enrollment token" "SENSOR_INSTANCE_ENROLLMENT_TOKEN" "$out"
reject "default: no enrollment Job" "sensor-enrollment" "$out"

# 2. instance: a generated token Secret, the Job, the sensor's variable.
out="$(render "${inst[@]}")"
expect "instance: token Secret" "name: t-openctem-sensor-enrollment" "$out"
if grep -Eq '^  token: "octe_[0-9A-Za-z]{49}"$' <<<"$out"; then pass "instance: token is octe_ + 49 letters or digits"; else fail "instance: token shape"; fi
expect "instance: Job" "name: t-openctem-api-sensor-enrollment" "$out"
expect "instance: Job after install and upgrade" '"helm.sh/hook": post-install,post-upgrade' "$out"
expect "instance: Job registers the value" '- "sensor-token"' "$out"
expect "instance: Job reads the token from the env" '- "SENSOR_INSTANCE_ENROLLMENT_TOKEN"' "$out"
expect "instance: Job has the API encryption key" "name: APP_ENCRYPTION_KEY" "$out"
expect "instance: Job removed once it succeeded" "before-hook-creation,hook-succeeded" "$out"
dep="$(render "${inst[@]}" -s templates/sensor-deployment.yaml)"
expect "instance: sensor reads the token from a file" "name: SENSOR_INSTANCE_ENROLLMENT_TOKEN_FILE" "$dep"
expect "instance: token file path" "value: /var/run/secrets/openctem/instance-enrollment/token" "$dep"
reject "instance: the token is not in the environment" "secretKeyRef" "$dep"
expect "instance: token Secret mounted read-only, group-readable only" "defaultMode: 0440" "$dep"
# sdk-go v0.35.0+: an identity enrolled at instance scope refuses to start
# without shared mode, which needs the sandbox and network confinement.
if grep -A1 'name: SENSOR_SHARED_MODE' <<<"$dep" | grep -q 'value: "1"'; then pass "instance: SENSOR_SHARED_MODE=1"; else fail "instance: SENSOR_SHARED_MODE=1"; fi
if grep -A1 'name: SENSOR_SANDBOX$' <<<"$dep" | grep -q 'value: required'; then pass "instance: SENSOR_SANDBOX=required"; else fail "instance: SENSOR_SANDBOX=required"; fi
if grep -A1 'name: SENSOR_SANDBOX_NETWORK' <<<"$dep" | grep -q 'value: "required"'; then pass "instance: SENSOR_SANDBOX_NETWORK=required"; else fail "instance: SENSOR_SANDBOX_NETWORK=required"; fi
expect "instance: local policy mounted" "name: SENSOR_LOCAL_POLICY" "$dep"
expect "instance: the sensor's own seccomp profile" "type: Localhost" "$dep"
pdep="$(render -s templates/sensor-deployment.yaml)"
reject "pairing: no shared mode" "SENSOR_SHARED_MODE" "$pdep"
reject "pairing: SENSOR_SANDBOX not forced" "name: SENSOR_SANDBOX$" "$pdep"
reject "instance: no API key on the sensor" "name: SENSOR_API_KEY" "$dep"
# The token is never an argument (visible in kubectl describe).
if grep -Eq 'octe_[0-9A-Za-z]{49}' <<<"$(render "${inst[@]}" -s templates/sensor-deployment.yaml)"; then
  fail "instance: token value rendered in the Deployment"
else
  pass "instance: the Deployment holds no token value"
fi

# 3. An existing Secret: nothing secret rendered, its name and key used.
out="$(render "${inst[@]}" --set sensor.instanceEnrollment.existingSecret=my-tok \
  --set sensor.instanceEnrollment.existingSecretKey=value)"
reject "existing secret: no generated token" "octe_" "$out"
expect "existing secret: name" "name: my-tok" "$out"
expect "existing secret: key" "key: value" "$out"

# 4. Refusals.
must_fail "instance with an API key" "leave sensor.apiKey and sensor.existingSecret empty" \
  "${inst[@]}" --set sensor.apiKey=octs_x
must_fail "instance with an API key Secret" "leave sensor.apiKey and sensor.existingSecret empty" \
  "${inst[@]}" --set sensor.existingSecret=k
must_fail "unknown enrollment" "enrollment" --set sensor.enrollment=bogus
# A shared sensor that could only crash-loop (and spend its single-use token)
# is refused at render time.
must_fail "instance without network confinement required" "set sensor.sandbox.network=required" \
  --set sensor.enrollment=instance --set sensor.localPolicy.enabled=true
must_fail "instance with sandbox auto" "set sensor.sandbox.network=required" \
  --set sensor.enrollment=instance --set sensor.sandbox.network=auto --set sensor.localPolicy.enabled=true
must_fail "instance with the runtime default seccomp profile" "seccomp" \
  --set sensor.enrollment=instance --set sensor.sandbox.network=required --set sensor.localPolicy.enabled=true \
  --set sensor.sandbox.seccompProfile=runtime-default
must_fail "instance without a local policy" "set sensor.localPolicy.enabled=true" \
  --set sensor.enrollment=instance --set sensor.sandbox.network=required
out="$(render "${inst[@]}" --set sensor.sandbox.seccompProfile=runtime-default \
  --set sensor.podSecurityContext.seccompProfile.type=Localhost --set sensor.podSecurityContext.seccompProfile.localhostProfile=own.json -s templates/sensor-deployment.yaml)"
expect "instance: an own Localhost seccomp profile is accepted" "localhostProfile: own.json" "$out"
must_fail "instance without a persistent identity" "identity must survive the pod" \
  "${inst[@]}" --set sensor.data.persistence.enabled=false


# Organization enrollment token: mounted from the named Secret as a file,
# never rendered and never in the environment; a Secret is required and an
# API key is refused.
out="$(render --set sensor.enrollment=token --set sensor.enrollmentToken.existingSecret=org-enroll)"
expect "token: file variable" "SENSOR_ENROLLMENT_TOKEN_FILE" "$out"
expect "token: secret volume" "secretName: org-enroll" "$out"
expect "token: default key" "key: token" "$out"
expect "token: not writable" "defaultMode: 0440" "$out"
reject "token: nothing secret rendered" "octe_" "$out"
reject "token: no instance token" "SENSOR_INSTANCE_ENROLLMENT_TOKEN" "$out"
reject "token: no registering Job" "sensor-enrollment" "$out"
must_fail "token: a Secret is required" "needs sensor.enrollmentToken.existingSecret" --set sensor.enrollment=token
must_fail "token: no API key" "enrolls the sensor with its own key" --set sensor.enrollment=token \
  --set sensor.enrollmentToken.existingSecret=org-enroll --set sensor.existingSecret=k

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all sensor-enrollment checks passed"
