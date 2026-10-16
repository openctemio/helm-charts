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

render() { helm template t "$chart" --set api.appEnv=development --set sensor.enabled=true "$@" 2>&1; }

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
out="$(render --set sensor.enrollment=instance)"
expect "instance: token Secret" "name: t-openctem-sensor-enrollment" "$out"
if grep -Eq '^  token: "octe_[0-9A-Za-z]{49}"$' <<<"$out"; then pass "instance: token is octe_ + 49 letters or digits"; else fail "instance: token shape"; fi
expect "instance: Job" "name: t-openctem-api-sensor-enrollment" "$out"
expect "instance: Job after install and upgrade" '"helm.sh/hook": post-install,post-upgrade' "$out"
expect "instance: Job registers the value" '- "sensor-token"' "$out"
expect "instance: Job reads the token from the env" '- "SENSOR_INSTANCE_ENROLLMENT_TOKEN"' "$out"
expect "instance: Job has the API encryption key" "name: APP_ENCRYPTION_KEY" "$out"
expect "instance: Job removed once it succeeded" "before-hook-creation,hook-succeeded" "$out"
dep="$(render --set sensor.enrollment=instance -s templates/sensor-deployment.yaml)"
expect "instance: sensor gets the token" "name: SENSOR_INSTANCE_ENROLLMENT_TOKEN" "$dep"
reject "instance: no API key on the sensor" "name: SENSOR_API_KEY" "$dep"
# The token is never an argument (visible in kubectl describe).
if grep -Eq 'octe_[0-9A-Za-z]{49}' <<<"$(render --set sensor.enrollment=instance -s templates/sensor-deployment.yaml)"; then
  fail "instance: token value rendered in the Deployment"
else
  pass "instance: the Deployment holds no token value"
fi

# 3. An existing Secret: nothing secret rendered, its name and key used.
out="$(render --set sensor.enrollment=instance --set sensor.instanceEnrollment.existingSecret=my-tok \
  --set sensor.instanceEnrollment.existingSecretKey=value)"
reject "existing secret: no generated token" "octe_" "$out"
expect "existing secret: name" "name: my-tok" "$out"
expect "existing secret: key" "key: value" "$out"

# 4. Refusals.
must_fail "instance with an API key" "leave sensor.apiKey and sensor.existingSecret empty" \
  --set sensor.enrollment=instance --set sensor.apiKey=octs_x
must_fail "instance with an API key Secret" "leave sensor.apiKey and sensor.existingSecret empty" \
  --set sensor.enrollment=instance --set sensor.existingSecret=k
must_fail "unknown enrollment" "enrollment" --set sensor.enrollment=bogus
must_fail "instance without a persistent identity" "identity must survive the pod" \
  --set sensor.enrollment=instance --set sensor.data.persistence.enabled=false

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all sensor-enrollment checks passed"
