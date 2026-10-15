#!/usr/bin/env bash
# Render checks for organization creation and the bootstrap-admin Job
# (api.signupMode, api.bootstrapAdmin.*, the removed api.bootstrapTenant).
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

# 1. Defaults: disabled, no bootstrap Job.
out="$(render)"
reject "default: no bootstrap Job" "bootstrap-admin" "$out"
out="$(render -s templates/api-deployment.yaml)"
expect "default: SIGNUP_MODE on the API" "name: SIGNUP_MODE" "$out"
expect "default: disabled" "value: disabled" "$out"
reject "default: no TENANT_CREATION_MODE" "TENANT_CREATION_MODE" "$out"

# 2. open and domain opt-ins.
out="$(render --set api.signupMode=open -s templates/api-deployment.yaml)"
expect "open: rendered" "value: open" "$out"
reject "open: no disabled" "value: disabled" "$out"
out="$(render --set api.signupMode=domain -s templates/api-deployment.yaml)"
expect "domain: rendered" "value: domain" "$out"

# 3. Unknown mode and the removed value fail.
must_fail "bad mode fails" 'api.signupMode="self_service" is not supported' --set api.signupMode=self_service
must_fail "removed api.tenantCreationMode fails" 'api.tenantCreationMode (TENANT_CREATION_MODE) is removed' --set api.tenantCreationMode=admin_only
must_fail "TENANT_CREATION_MODE in extraEnv fails" 'set api.signupMode instead' \
  --set 'api.extraEnv[0].name=TENANT_CREATION_MODE' --set 'api.extraEnv[0].value=self_service'

# 4. api.extraEnv wins, without a duplicate env name.
out="$(render --set 'api.extraEnv[0].name=SIGNUP_MODE' --set 'api.extraEnv[0].value=open' -s templates/api-deployment.yaml)"
n="$(grep -c 'name: SIGNUP_MODE' <<<"$out" || true)"
if [ "$n" = "1" ]; then pass "extraEnv override: one SIGNUP_MODE"; else fail "extraEnv override: $n SIGNUP_MODE entries"; fi
expect "extraEnv override: value kept" "value: open" "$out"

# 5. Full bootstrap: admin + backup + first org.
BA=(--set api.bootstrapAdmin.enabled=true --set api.bootstrapAdmin.email=admin@acme.io
  --set api.bootstrapAdmin.backupEmail=bg@acme.io)
out="$(render "${BA[@]}" --set 'api.bootstrapAdmin.org.name=Acme Security' \
  --set api.bootstrapAdmin.org.ownerEmail=owner@acme.io \
  --set 'api.bootstrapAdmin.org.ownerName=Jo $(DB_PASSWORD)' \
  --set 'api.extraEnv[0].name=APP_NAME' --set 'api.extraEnv[0].value=acme-ctem' \
  --set 'api.bootstrapAdmin.extraEnv[0].name=BOOTSTRAP_SMTP_HOST' --set 'api.bootstrapAdmin.extraEnv[0].value=smtp.acme.io' \
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
expect "job: api.extraEnv" "name: APP_NAME" "$out"
expect "job: api.bootstrapAdmin.extraEnv (BOOTSTRAP_SMTP_*)" "name: BOOTSTRAP_SMTP_HOST" "$out"
expect "job: api.extraEnvFrom" "name: smtp" "$out"
expect "job: SIGNUP_MODE" "name: SIGNUP_MODE" "$out"
expect "job: APP_ENCRYPTION_KEY (stores and reads the platform SMTP settings)" "name: APP_ENCRYPTION_KEY" "$out"
expect "job: credentials outside the URL" 'value: "postgres://$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=$(DB_SSLMODE)"' "$out"
expect "job: PGPASSWORD" 'name: PGPASSWORD' "$out"
expect "job: no service account token" "automountServiceAccountToken: false" "$out"
expect "job: /tmp writable" "mountPath: /tmp" "$out"
reject "api: BOOTSTRAP_SMTP_* stay out of the API" "BOOTSTRAP_SMTP" "$(render "${BA[@]}" --set 'api.bootstrapAdmin.extraEnv[0].name=BOOTSTRAP_SMTP_HOST' --set 'api.bootstrapAdmin.extraEnv[0].value=x' -s templates/api-deployment.yaml)"

# 5b. The SMTP server moved to the admin console: SMTP_* in api.extraEnv makes
#     the API refuse to start, so the render fails first and says where it went.
must_fail "SMTP_HOST in api.extraEnv fails" "BOOTSTRAP_SMTP_* in api.bootstrapAdmin.extraEnv" \
  --set 'api.extraEnv[0].name=SMTP_HOST' --set 'api.extraEnv[0].value=smtp.acme.io'

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
