#!/usr/bin/env bash
# Render checks for API attachment storage (api.attachments): the default
# ReadWriteOnce volume, S3, a ReadWriteMany volume for several replicas, and
# the combinations that must refuse to render.
# Usage: tests/attachments/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

render() { helm template t "$chart" --set api.appEnv=development "$@" 2>&1; }
multi=(--set api.allowMultipleReplicas=true)

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

# 1. Default: one replica, a ReadWriteOnce PVC at /app/data, Recreate strategy.
out="$(render)"
expect "default: attachments PVC" "name: t-openctem-api-attachments" "$out"
expect "default: PVC kept on uninstall" "helm.sh/resource-policy: keep" "$out"
dep="$(render -s templates/api-deployment.yaml)"
expect "default: local provider" 'value: "local"' "$dep"
expect "default: STORAGE_LOCAL_PATH" 'value: "/app/data/attachments"' "$dep"
expect "default: mounted at /app/data" "mountPath: /app/data" "$dep"
expect "default: claim" "claimName: t-openctem-api-attachments" "$dep"
expect "default: Recreate for a RWO volume" "type: Recreate" "$dep"

# 2. An explicit deploymentStrategy wins.
dep="$(render -s templates/api-deployment.yaml --set api.deploymentStrategy.type=RollingUpdate)"
expect "deploymentStrategy wins" "type: RollingUpdate" "$dep"
reject "deploymentStrategy wins: no Recreate" "type: Recreate" "$dep"

# 3. Single replica without persistence: emptyDir.
dep="$(render -s templates/api-deployment.yaml --set api.attachments.persistence.enabled=false)"
expect "no persistence: emptyDir" "emptyDir: {}" "$dep"
reject "no persistence: no Recreate" "type: Recreate" "$dep"

# 4. S3: env from a chart Secret, no volume, no PVC.
s3=(--set api.attachments.storage=s3 --set api.attachments.s3.bucket=att --set api.attachments.s3.endpoint=http://minio:9000 --set api.attachments.s3.provider=minio --set api.attachments.s3.accessKey=AK --set api.attachments.s3.secretKey=SK)
out="$(render "${s3[@]}" "${multi[@]}" --set api.replicaCount=3)"
expect "s3: provider" 'value: "minio"' "$out"
expect "s3: bucket" 'value: "att"' "$out"
expect "s3: endpoint" 'value: "http://minio:9000"' "$out"
expect "s3: access key from the Secret" "name: STORAGE_ACCESS_KEY" "$out"
expect "s3: chart Secret" "name: t-openctem-api-storage" "$out"
reject "s3: no PVC" "t-openctem-api-attachments" "$out"
reject "s3: no /app/data mount" "mountPath: /app/data" "$out"
out="$(render --set api.attachments.storage=s3 --set api.attachments.s3.bucket=att --set api.attachments.s3.existingSecret=mys3)"
expect "s3 existingSecret: referenced" "name: mys3" "$out"
reject "s3 existingSecret: no chart Secret" "name: t-openctem-api-storage" "$out"

# 5. Several replicas on a ReadWriteMany volume.
out="$(render "${multi[@]}" --set api.replicaCount=3 --set 'api.attachments.persistence.accessModes={ReadWriteMany}')"
expect "rwx: PVC is ReadWriteMany" "- ReadWriteMany" "$out"
reject "rwx: no Recreate" "type: Recreate" "$(render -s templates/api-deployment.yaml "${multi[@]}" --set api.replicaCount=3 --set 'api.attachments.persistence.accessModes={ReadWriteMany}')"

# 6. Refused.
must_fail "3 replicas on a RWO volume" "only one pod (one node) can mount it" --set api.replicaCount=3
must_fail "autoscaling on a RWO volume" "The API can run 5 replicas" --set api.autoscaling.enabled=true --set api.autoscaling.maxReplicas=5
must_fail "2 replicas without persistence" "keeps attachments on each pod's own disk" --set api.replicaCount=2 --set api.attachments.persistence.enabled=false
must_fail "s3 without bucket" "needs api.attachments.s3.bucket" --set api.attachments.storage=s3 --set api.attachments.s3.accessKey=AK --set api.attachments.s3.secretKey=SK
must_fail "s3 without credentials" "needs credentials" --set api.attachments.storage=s3 --set api.attachments.s3.bucket=att
must_fail "unknown storage" 'api.attachments.storage="gcs" is not supported' --set api.attachments.storage=gcs
must_fail "unknown s3 provider" 'api.attachments.s3.provider="gcs" is not supported' "${s3[@]}" --set api.attachments.s3.provider=gcs

# API replica guard: more than one API replica needs an explicit opt-in.
must_fail "2 replicas without opt-in" "not yet safe with more than one replica" "${s3[@]}" --set api.replicaCount=2
must_fail "autoscaling to 4 without opt-in" "not yet safe with more than one replica" "${s3[@]}" --set api.autoscaling.enabled=true --set api.autoscaling.maxReplicas=4
out="$(render "${s3[@]}" "${multi[@]}" --set api.replicaCount=2)" || fail "2 replicas with opt-in should render"

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all attachment storage checks passed"
