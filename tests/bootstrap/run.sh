#!/usr/bin/env bash
# Render checks for organization creation and the bootstrap-admin Job
# (api.tenantCreationMode, api.bootstrapAdmin.*, the removed api.bootstrapTenant).
# Usage: tests/bootstrap/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

render() { helm template t "$chart" --set api.appEnv=development "$@" 2>&1; }

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

# 1. Defaults: admin_only, no bootstrap Job.
out="$(render)"
reject "default: no bootstrap Job" "bootstrap-admin" "$out"
out="$(render -s templates/api-deployment.yaml)"
expect "default: TENANT_CREATION_MODE on the API" "name: TENANT_CREATION_MODE" "$out"
expect "default: admin_only" "value: admin_only" "$out"

# 2. self_service opt-in.
out="$(render --set api.tenantCreationMode=self_service)"
expect "self_service: rendered" "value: self_service" "$out"
reject "self_service: no admin_only" "value: admin_only" "$out"

# 3. Unknown mode fails.
must_fail "bad mode fails" 'api.tenantCreationMode="open" is not supported' --set api.tenantCreationMode=open

# 4. api.extraEnv wins, without a duplicate env name.
out="$(render --set 'api.extraEnv[0].name=TENANT_CREATION_MODE' --set 'api.extraEnv[0].value=self_service' -s templates/api-deployment.yaml)"
n="$(grep -c 'name: TENANT_CREATION_MODE' <<<"$out" || true)"
if [ "$n" = "1" ]; then pass "extraEnv override: one TENANT_CREATION_MODE"; else fail "extraEnv override: $n TENANT_CREATION_MODE entries"; fi
expect "extraEnv override: value kept" "value: self_service" "$out"

# 5. Full bootstrap: admin + backup + first org.
BA=(--set api.bootstrapAdmin.enabled=true --set api.bootstrapAdmin.email=admin@acme.io
  --set api.bootstrapAdmin.backupEmail=bg@acme.io)
out="$(render "${BA[@]}" --set 'api.bootstrapAdmin.org.name=Acme Security' \
  --set api.bootstrapAdmin.org.ownerEmail=owner@acme.io \
  --set 'api.bootstrapAdmin.org.ownerName=Jo $(DB_PASSWORD)' \
  --set 'api.extraEnv[0].name=SMTP_HOST' --set 'api.extraEnv[0].value=smtp.acme.io' \
  --set 'api.extraEnvFrom[0].secretRef.name=smtp' -s templates/api-bootstrap-job.yaml)"
expect "job: no shell" 'command: ["/app/bootstrap-admin"]' "$out"
reject "job: no failure swallowing" "|| echo" "$out"
reject "job: no ttlSecondsAfterFinished" "ttlSecondsAfterFinished" "$out"
expect "job: kept after success" '"helm.sh/hook-delete-policy": before-hook-creation' "$out"
reject "job: not deleted on success" "hook-succeeded" "$out"
expect "job: backoffLimit 0" "backoffLimit: 0" "$out"
expect "job: -email" '- "-email=admin@acme.io"' "$out"
expect "job: -backup-email" '- "-backup-email=bg@acme.io"' "$out"
expect "job: -org-name with a space" '- "-org-name=Acme Security"' "$out"
expect "job: -org-owner-email" '- "-org-owner-email=owner@acme.io"' "$out"
expect "job: \$ escaped for k8s expansion" '- "-org-owner-name=Jo $$(DB_PASSWORD)"' "$out"
reject "job: no -org-slug when unset" "-org-slug" "$out"
expect "job: api.extraEnv (SMTP)" "name: SMTP_HOST" "$out"
expect "job: api.extraEnvFrom" "name: smtp" "$out"
expect "job: TENANT_CREATION_MODE" "name: TENANT_CREATION_MODE" "$out"

# 6. Admin only, no org: no -org-* flags.
out="$(render "${BA[@]}" -s templates/api-bootstrap-job.yaml)"
reject "job without org: no -org flags" "-org-" "$out"

# 7. Half an org fails.
must_fail "org.name without ownerEmail fails" "org.ownerEmail is not" "${BA[@]}" --set api.bootstrapAdmin.org.name=Acme
must_fail "org.ownerEmail without name fails" "org.name is not" "${BA[@]}" --set api.bootstrapAdmin.org.ownerEmail=o@acme.io

# 8. The removed api.bootstrapTenant fails with a pointer.
must_fail "bootstrapTenant.enabled fails" "api.bootstrapAdmin.org.name" --set api.bootstrapTenant.enabled=true
if render --set api.bootstrapTenant.enabled=false >/dev/null; then
  pass "bootstrapTenant.enabled=false still renders"
else
  fail "bootstrapTenant.enabled=false still renders"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all bootstrap checks passed"
