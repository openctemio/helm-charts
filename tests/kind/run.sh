#!/usr/bin/env bash
# Install smoke test on a kind cluster (needs kind, kubectl, helm, docker and
# a running cluster: KIND_CLUSTER, default "chart-smoke").
#
# 1. The chart installs on a real API server in dev/eval mode with the
#    bundled PostgreSQL and Redis, which become ready. When the chart's
#    appVersion images are not published yet, the platform is installed
#    without hooks (the migrations Job would wait for an image that does not
#    exist) and its API/UI pods are not waited for.
# 2. The bundled sensor, in its default mode (pairing, no API key):
#    - it imports the nuclei-templates release baked into its image (nothing
#      is mounted over its home directory) and detects its scanners;
#    - it starts pairing and keeps its key in the state volume;
#    - after its pod is replaced, the kubelet has not made the identity
#      group-readable (fsGroupChangePolicy OnRootMismatch) and the sensor
#      accepts it. A local PersistentVolume is used because the kubelet
#      applies fsGroup to it (kind's default hostPath provisioner is exempt).
#    - control: with fsGroupChangePolicy Always the same replacement makes
#      the sensor refuse its identity, so the check above can fail.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
cluster="${KIND_CLUSTER:-chart-smoke}"
node="${KIND_NODE:-$cluster-control-plane}"
ns="${NAMESPACE:-openctem-smoke}"
rel="smoke"
sensor="deploy/$rel-openctem-sensor"
pv_dir="/var/local-pv/$ns-sensor-state"
timeout="${TIMEOUT:-600}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

kubectl config use-context "kind-$cluster" >/dev/null
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# A local PersistentVolume for the sensor state (fsGroup applies to it).
docker exec "$node" mkdir -p "$pv_dir"
kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smoke-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $ns-sensor-state
spec:
  capacity:
    storage: 128Mi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: smoke-local
  local:
    path: $pv_dir
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$node]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sensor-state
  namespace: $ns
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: smoke-local
  volumeName: $ns-sensor-state
  resources:
    requests:
      storage: 128Mi
EOF

app="$(sed -nE 's/^appVersion:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$chart/Chart.yaml")"
published=0
if docker manifest inspect "ghcr.io/openctemio/openctem-api:$app" >/dev/null 2>&1; then
  published=1
fi
install=(upgrade --install "$rel" "$chart" -n "$ns"
  --set api.appEnv=development
  --set sensor.enabled=true
  --set sensor.state.persistence.existingClaim=sensor-state
  --set sensor.content.persistence.size=1Gi)
if [[ $published == 1 ]]; then
  helm "${install[@]}" --wait --timeout "${timeout}s" >/dev/null
  pass "platform $app installed with hooks and became ready"
else
  echo "notice: ghcr.io/openctemio/openctem-api:$app is not published; installing the platform without hooks and not waiting for the API/UI"
  helm "${install[@]}" --no-hooks >/dev/null
  pass "chart installed (API/UI images $app not published yet)"
fi

for sts in "$rel-postgresql" "$rel-redis-master"; do
  if kubectl -n "$ns" rollout status "statefulset/$sts" --timeout="${timeout}s" >/dev/null; then
    pass "bundled datastore $sts ready"
  else
    fail "bundled datastore $sts ready"
  fi
done

# The sensor's log since its newest container started (it exits and restarts
# while no API answers, so read the previous container's log as well).
sensor_log() {
  local pod
  pod="$(kubectl -n "$ns" get pod -l app.kubernetes.io/component=sensor \
    --field-selector=status.phase!=Succeeded -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || return 0
  kubectl -n "$ns" logs "$pod" 2>/dev/null || true
  kubectl -n "$ns" logs "$pod" --previous 2>/dev/null || true
}
# Wait until the sensor log contains one of the given patterns (grep -E).
wait_log() {
  local pattern="$1" deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if sensor_log | grep -Eq "$pattern"; then return 0; fi
    sleep 2
  done
  return 1
}
# Replace the sensor pod: scale to 0 and back, so the volume is mounted again.
replace_pod() {
  kubectl -n "$ns" scale "$sensor" --replicas=0 >/dev/null
  kubectl -n "$ns" wait --for=delete pod -l app.kubernetes.io/component=sensor --timeout="${timeout}s" >/dev/null 2>&1 || true
  kubectl -n "$ns" scale "$sensor" --replicas=1 >/dev/null
}
# The identity's modes and the content versions' links, read by a pod
# without fsGroup (it changes nothing).
identity_modes() {
  kubectl -n "$ns" scale "$sensor" --replicas=0 >/dev/null
  kubectl -n "$ns" wait --for=delete pod -l app.kubernetes.io/component=sensor --timeout="${timeout}s" >/dev/null 2>&1 || true
  kubectl -n "$ns" delete pod state-check --ignore-not-found --wait >/dev/null
  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: state-check
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
  containers:
    - name: check
      image: $(kubectl -n "$ns" get "$sensor" -o jsonpath='{.spec.template.spec.containers[0].image}')
      command: ["/bin/sh", "-c", "stat -c '%a %n' /state/identity /state/identity/*; find /content -type l -exec readlink {} ';' | sed 's/^/link /'"]
      volumeMounts:
        - name: state
          mountPath: /state
        - name: content
          mountPath: /content
  volumes:
    - name: state
      persistentVolumeClaim:
        claimName: sensor-state
    - name: content
      persistentVolumeClaim:
        claimName: $rel-openctem-sensor-content
EOF
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/state-check --timeout="${timeout}s" >/dev/null || true
  kubectl -n "$ns" logs state-check
  kubectl -n "$ns" delete pod state-check --wait >/dev/null
  kubectl -n "$ns" scale "$sensor" --replicas=1 >/dev/null
}

# 2a. First start: scanners, pairing.
if wait_log "This sensor has no identity yet; pairing with"; then
  pass "sensor pairs without an API key"
else
  fail "sensor pairs without an API key"
fi
log="$(sensor_log)"
if grep -Eq "Tools: .*nuclei.*subfinder.*katana" <<<"$log"; then
  pass "sensor detects nuclei and the recon tools"
else
  fail "sensor detects nuclei and the recon tools"
fi

# 2b. The identity stays 0700/0600 across a pod replacement.
modes="$(identity_modes)"
echo "$modes" | sed 's/^/     /'
# The directory may carry the setgid bit it inherits from the volume root
# (fsGroup); the sensor checks the permission bits only.
if grep -Eq "^2?700 /state/identity$" <<<"$modes" && grep -q "^600 /state/identity/signing.key$" <<<"$modes"; then
  pass "identity created 0700/0600"
else
  fail "identity created 0700/0600"
fi
# The content store adopted the baked release: its first version links to
# the image's /home/openctem/nuclei-templates (visible, not mounted over).
if grep -q "^link /home/openctem/nuclei-templates" <<<"$modes"; then
  pass "sensor adopted the nuclei-templates baked into its image"
else
  fail "sensor adopted the nuclei-templates baked into its image"
fi
replace_pod
modes="$(identity_modes)"
if grep -q "^600 /state/identity/signing.key$" <<<"$modes"; then
  pass "identity still 0600 after the pod was replaced"
else
  fail "identity still 0600 after the pod was replaced: $modes"
fi
if wait_log "pairing with|has mode"; then
  if sensor_log | grep -q "has mode"; then
    fail "sensor accepts its identity after the pod was replaced"
  else
    pass "sensor accepts its identity after the pod was replaced"
  fi
else
  fail "sensor restarted after the pod was replaced"
fi

# 2c. Control: the kubelet's default policy breaks the identity.
helm "${install[@]}" --no-hooks --reuse-values \
  --set sensor.podSecurityContext.fsGroupChangePolicy=Always >/dev/null
replace_pod
if wait_log "identity: .* has mode"; then
  pass "control: fsGroupChangePolicy Always makes the sensor refuse its identity"
else
  fail "control: fsGroupChangePolicy Always makes the sensor refuse its identity"
fi

if [[ $fails -gt 0 ]]; then
  echo "$fails failed"
  kubectl -n "$ns" get pods -o wide || true
  exit 1
fi
echo "all kind install checks passed"
