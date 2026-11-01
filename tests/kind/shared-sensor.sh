#!/usr/bin/env bash
# The bundled sensor as a shared sensor of the instance, on a kind cluster
# (needs kind, kubectl, helm, docker and a running cluster: KIND_CLUSTER,
# default "chart-shared"; the node must allow unprivileged user namespaces,
# e.g. kernel.apparmor_restrict_unprivileged_userns=0 on Ubuntu 23.10+).
#
# 1. The platform installs with its hooks (migrations, then the
#    sensor-enrollment Job that registers the chart's single-use token).
# 2. The sensor (sensor.enrollment=instance) enrolls as a shared sensor,
#    starts in shared mode (sandbox and network confinement required, the
#    local policy loaded) and stays up: no container restart for
#    STAY_SECONDS, and the platform records it as an instance-scope sensor
#    that heartbeats (sensors.last_seen_at moves).
#    Before this chart fixed it, the sensor spent its token, then stopped
#    ("enrolled as a shared sensor of the instance; set SENSOR_SHARED_MODE=1")
#    and crash-looped.
# 3. The sensor NetworkPolicy, from a probe pod carrying the sensor's labels
#    (the policy selects by label; the sensor image has no shell), compared
#    with a control pod without them: the probe reaches the API and the
#    internet but not PostgreSQL, Redis or the Kubernetes API service, which
#    the control reaches. Only meaningful on a CNI that enforces
#    NetworkPolicy (kind's kindnet does since kind v0.24); the control
#    proves the targets are reachable at all.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
cluster="${KIND_CLUSTER:-chart-shared}"
ns="${NAMESPACE:-openctem-shared}"
rel="shared"
sensor="deploy/$rel-openctem-sensor"
timeout="${TIMEOUT:-900}"
stay="${STAY_SECONDS:-120}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

kubectl config use-context "kind-$cluster" >/dev/null
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

app="$(sed -nE 's/^appVersion:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$chart/Chart.yaml")"
if ! docker manifest inspect "ghcr.io/openctemio/openctem-api:$app" >/dev/null 2>&1; then
  # Enrollment needs the API and its migrations: nothing to run against.
  echo "notice: ghcr.io/openctemio/openctem-api:$app is not published; the shared sensor run needs the API, skipped"
  exit 0
fi

# The host owner's local policy: public targets only, scan/validate/retest.
policy="$(mktemp)"
cat >"$policy" <<'EOF'
sensor:
  localPolicy:
    enabled: true
    policy: |
      apiVersion: openctem.io/sensor-policy/v1
      targets:
        allow_private: false
      checks:
        allow: [scan, validate, retest, refresh_content]
      allow_custom_templates: false
      allow_interactsh: false
      rate:
        max_rps: 100
        max_job_seconds: 14400
EOF
install=(upgrade --install "$rel" "$chart" -n "$ns" -f "$policy"
  --set api.appEnv=development
  --set sensor.enabled=true --set sensor.allowInsecureHTTP=true
  --set sensor.enrollment=instance
  --set sensor.sandbox.network=required
  --set sensor.content.persistence.size=1Gi)
if ! docker manifest inspect "ghcr.io/openctemio/openctem-console:$app" >/dev/null 2>&1; then
  install+=(--set console.enabled=false)
fi
# No --wait: the migrations and enrollment Jobs are post-install hooks.
helm "${install[@]}" --timeout "${timeout}s" >/dev/null
pass "platform $app installed with hooks (migrations and sensor-enrollment Jobs completed)"
if kubectl -n "$ns" rollout status "deploy/$rel-openctem-api" --timeout="${timeout}s" >/dev/null; then
  pass "API ready"
else
  fail "API ready"
fi

sensor_pod() {
  kubectl -n "$ns" get pod -l app.kubernetes.io/component=sensor \
    --field-selector=status.phase!=Succeeded -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
sensor_log() {
  local pod
  pod="$(sensor_pod)"
  [[ -n "$pod" ]] || return 0
  kubectl -n "$ns" logs "$pod" 2>/dev/null || true
  kubectl -n "$ns" logs "$pod" --previous 2>/dev/null || true
}
wait_log() {
  local pattern="$1" deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if sensor_log | grep -Eq "$pattern"; then return 0; fi
    sleep 3
  done
  return 1
}
restarts() {
  kubectl -n "$ns" get pod "$(sensor_pod)" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?"
}
psql_q() {
  kubectl -n "$ns" exec "$rel-postgresql-0" -c postgresql -- sh -c \
    'PGPASSWORD="${POSTGRES_PASSWORD:-$(cat "$POSTGRES_PASSWORD_FILE" 2>/dev/null)}" psql -h 127.0.0.1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DATABASE:-${POSTGRES_DB:-postgres}}" -tAc "$0"' "$1" 2>/dev/null || true
}

# 2. Enrolled as a shared sensor, in shared mode, and stays up.
if wait_log "Enrolled: shared sensor"; then
  pass "sensor enrolled as a shared sensor of the instance"
else
  fail "sensor enrolled as a shared sensor of the instance"
fi
if sensor_log | grep -q "Shared mode: every job sandboxed and network-confined"; then
  pass "sensor runs in shared mode (sandboxed, network-confined)"
else
  fail "sensor runs in shared mode (sandboxed, network-confined)"
fi
if sensor_log | grep -q "SENSOR_SHARED_MODE=1"; then
  fail "sensor refused its identity for want of shared mode"
else
  pass "no shared-mode refusal in the sensor log"
fi
first="$(psql_q "select last_seen_at from sensors where scope = 'instance' order by created_at desc limit 1")"
r0="$(restarts)"
sleep "$stay"
r1="$(restarts)"
if [[ "$r0" == "$r1" && "$(kubectl -n "$ns" get pod "$(sensor_pod)" -o jsonpath='{.status.phase}')" == Running ]]; then
  pass "sensor stayed up ${stay}s without a restart (restarts: $r1)"
else
  fail "sensor stayed up ${stay}s without a restart (restarts: $r0 -> $r1)"
fi
last="$(psql_q "select last_seen_at from sensors where scope = 'instance' order by created_at desc limit 1")"
if [[ -n "$last" && "$last" != "$first" ]]; then
  pass "platform lists an instance-scope sensor that heartbeats ($first -> $last)"
else
  fail "platform lists an instance-scope sensor that heartbeats (before: '$first', after: '$last')"
fi

# 3. The sensor NetworkPolicy, probe (sensor labels) against control.
check_image="public.ecr.aws/docker/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
probe_pod() { # name labels(json)
  kubectl -n "$ns" delete pod "$1" --ignore-not-found --wait >/dev/null
  kubectl -n "$ns" run "$1" --image="$check_image" --restart=Never --labels="$2" \
    --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$1"'","image":"'"$check_image"'","command":["sleep","600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  kubectl -n "$ns" wait --for=condition=Ready "pod/$1" --timeout=120s >/dev/null
}
can() { # pod host port
  kubectl -n "$ns" exec "$1" -- nc -z -w 4 "$2" "$3" </dev/null >/dev/null 2>&1
}
probe_pod np-probe "app.kubernetes.io/name=openctem,app.kubernetes.io/instance=$rel,app.kubernetes.io/component=sensor"
probe_pod np-control "app.kubernetes.io/name=np-control"
api_svc="$rel-openctem-api"
for t in "PostgreSQL $rel-postgresql 5432" "Redis $rel-redis-master 6379" "Kubernetes-API kubernetes.default.svc 443"; do
  read -r what host port <<<"$t"
  if can np-control "$host" "$port"; then
    if can np-probe "$host" "$port"; then
      fail "sensor pods cannot reach $what ($host:$port)"
    else
      pass "sensor pods cannot reach $what; the control pod can"
    fi
  else
    fail "control pod reaches $what ($host:$port), so the check means something"
  fi
done
api_port="$(kubectl -n "$ns" get svc "$api_svc" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')"
if can np-probe "$api_svc" "${api_port:-80}"; then
  pass "sensor pods reach the API"
else
  fail "sensor pods reach the API"
fi
if can np-probe github.com 443; then
  pass "sensor pods reach the internet (DNS and github.com:443)"
else
  fail "sensor pods reach the internet (DNS and github.com:443)"
fi
kubectl -n "$ns" delete pod np-probe np-control --wait=false >/dev/null

if [[ $fails -gt 0 ]]; then
  echo "$fails failed"
  kubectl -n "$ns" get pods -o wide || true
  sensor_log | tail -n 60 || true
  exit 1
fi
echo "all shared sensor checks passed"
