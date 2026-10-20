#!/usr/bin/env bash
# Render checks for the job signer sidecar (api.signer): production refuses to
# render without it, the signer is hardened and isolated from the API
# container, and the key and state volumes reach the signer container only.
# Usage: tests/signer/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
prod="$chart/values-production.yaml"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
refused() { # description, message, helm args...
  local d="$1" m="$2" out; shift 2
  if out="$(helm template t "$chart" "$@" 2>&1)"; then fail "$d (rendered)"; else expect "$d" "$m" "$out"; fi
}
render() { helm template t "$chart" "$@"; }

# 1. Refusals.
refused "production without the signer" "api.signer.enabled=false with api.appEnv=production" -f "$prod" --set api.signer.enabled=false
refused "production without a key source" "needs a signing key" -f "$prod" --set api.signer.key.existingSecret=
refused "key Secret and generate together" "are alternatives" -f "$prod" --set api.signer.key.generate=true
refused "unsigned jobs allowed in production" "SIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS" -f "$prod" \
  --set 'api.extraEnv[0].name=SIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS' --set 'api.extraEnv[0].value=true'
refused "AI_TRIAGE_ENABLED in api.extraEnv (removed in OpenCTEM v0.12.0)" "AI_TRIAGE_ENABLED" -f "$prod" \
  --set 'api.extraEnv[0].name=AI_TRIAGE_ENABLED' --set 'api.extraEnv[0].value=true'
refused "SIGNER_SOCKET in api.extraEnv next to the sidecar" "SIGNER_SOCKET is set in api.extraEnv" -f "$prod" \
  --set 'api.extraEnv[0].name=SIGNER_SOCKET' --set 'api.extraEnv[0].value=/x'
refused "two API replicas" "single-replica" -f "$prod" --set api.replicaCount=2 --set api.allowMultipleReplicas=true
refused "service account token in the pod" "api.serviceAccount.automount=false" -f "$prod" --set api.serviceAccount.automount=true
refused "signer as the API's user" "must differ from the API's user" -f "$prod" --set api.signer.runAsUser=1000
refused "unknown ledger mode" "mode" -f "$prod" --set api.signer.ledger.mode=off
# Development may run without it.
render --set api.appEnv=development --set api.signer.enabled=false >/dev/null && pass "development without the signer renders" || fail "development without the signer renders"

# 2. The production render.
all="$(render -f "$prod")"
api="$(render -f "$prod" -s templates/api-deployment.yaml)"
expect "API gets SIGNER_SOCKET" "$(printf -- '- name: SIGNER_SOCKET\n              value: /run/openctem-signer/signer.sock')" "$api"
expect "ledger mode defaults to audit" "$(printf -- '- name: SIGNER_LEDGER\n              value: "audit"')" "$api"
expect "Recreate strategy (single-writer volumes)" "type: Recreate" "$api"
reject "no SIGNER_GENERATE_KEY with an existing Secret" "SIGNER_GENERATE_KEY" "$api"
reject "no AI_TRIAGE_ENABLED" "AI_TRIAGE_ENABLED" "$all"
reject "no TENANT_CREATION_MODE" "TENANT_CREATION_MODE" "$all"
reject "no service account token" "automountServiceAccountToken: true" "$api"
expect "bootstrap Job prints its one-time credentials" '"-print-secrets"' "$(render -f "$prod" --set api.bootstrapAdmin.enabled=true --set api.bootstrapAdmin.email=a@example.com --set api.bootstrapAdmin.backupEmail=b@example.com -s templates/api-bootstrap-job.yaml)"

# Container by container (the pod holds api, signer and the init container).
python3 - "$api" <<'PY' && pass "signer isolation (hardening, mounts, uids)" || fail "signer isolation"
import sys, re
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(sys.argv[1])
spec = d["spec"]["template"]["spec"]
c = {x["name"]: x for x in spec["containers"] + spec.get("initContainers", [])}
sg, ap, init = c["signer"], c["api"], c["signer-key-install"]
for name, x in (("signer", sg), ("init", init)):
    s = x["securityContext"]
    assert s["runAsNonRoot"] and s["runAsUser"] == 1001 and s["runAsUser"] != ap["securityContext"]["runAsUser"], name
    assert s["readOnlyRootFilesystem"] and not s["allowPrivilegeEscalation"], name
    assert s["capabilities"]["drop"] == ["ALL"], name
assert spec["automountServiceAccountToken"] is False
mounts = lambda x: {m["name"] for m in x.get("volumeMounts", [])}
assert "signer-socket" in mounts(ap)
for v in ("signer-keys", "signer-state", "signer-key-source", "signer-keyset"):
    assert v not in mounts(ap), "API mounts " + v
assert mounts(sg) == {"signer-socket", "signer-state", "signer-keys"}, mounts(sg)
assert mounts(init) == {"signer-key-source", "signer-keys"}
assert not any("ports" in x for x in (sg, init))
PY

# 3. Generated key (opt-in): a PVC for the key, no Secret, no init container.
gen="$(render -f "$prod" --set api.signer.key.existingSecret= --set api.signer.key.generate=true)"
expect "generate: SIGNER_GENERATE_KEY" 'SIGNER_GENERATE_KEY' "$gen"
expect "generate: key claim" "name: t-openctem-api-signer-keys" "$gen"
reject "generate: no init container" "signer-key-install" "$gen"
expect "state claim" "name: t-openctem-api-signer-state" "$all"
# Dev/eval defaults to a generated key.
dev="$(render --set api.appEnv=development)"
expect "development generates the key" "SIGNER_GENERATE_KEY" "$dev"
# Enforce mode and the key set.
enf="$(render -f "$prod" --set api.signer.ledger.mode=enforce --set api.signer.keyset.existingSecret=ks -s templates/api-deployment.yaml)"
expect "enforce" 'value: "enforce"' "$enf"
expect "key set file" "SIGNER_KEYSET_FILE" "$enf"

if [[ $fails -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all signer checks passed"
