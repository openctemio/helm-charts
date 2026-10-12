#!/usr/bin/env bash
# Render checks for the production posture: fail-fast on what the API would
# refuse at boot, read-only root filesystems, no service account tokens,
# probes, datastore TLS trust, credentials kept out of URLs, and the size
# presets leaving the operator's api.extraEnv alone.
# Usage: tests/production/run.sh  (needs helm; dependencies built)
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

# 1. What the API refuses at boot fails the render first.
refused "production + bundled Redis" "the bundled Redis has no TLS" -f "$prod" --set redis.enabled=true
refused "production + Redis without TLS" "api.redis.tlsEnabled=false" -f "$prod" --set api.redis.tlsEnabled=false
refused "production + unverified Redis TLS" "api.redis.tlsSkipVerify=true" -f "$prod" --set api.redis.tlsSkipVerify=true
refused "production + sslmode disable" "sslmode is disable" -f "$prod" --set api.migrations.sslMode=disable
refused "production + insecure cookies" "api.auth.cookieSecure=false" -f "$prod" --set api.auth.cookieSecure=false
refused "external database without a host" "needs database.host" -f "$prod" --set database.host=
refused "external database without credentials" "The external database needs credentials" \
  -f "$prod" --set database.auth.existingSecret= --set database.auth.createSecret=true
refused "external Redis without a host" "needs redisConfig.host" -f "$prod" --set redisConfig.host=
refused "external Redis without a password" "The external Redis needs a password" \
  -f "$prod" --set redisConfig.auth.existingSecret= --set redisConfig.auth.createSecret=true
# The schema error wording differs between Helm 3 and Helm 4: match the key.
refused "values outside the schema" "gatway" -f "$prod" --set gatway.mode=caddy
refused "SMTP_* in api.extraEnv (moved to the admin console)" "Console > System > E-mail" \
  -f "$prod" --set 'api.extraEnv[0].name=SMTP_HOST' --set 'api.extraEnv[0].value=x'

# 2. The production example keeps every credential in a Secret.
out="$(render -f "$prod")"
reject "production example: no chart-made database Secret" "name: t-openctem-api-db" "$out"
reject "production example: no chart-made Redis Secret" "name: t-openctem-api-redis" "$out"
reject "production example: no chart-made app Secret" "name: t-openctem-api-app" "$out"
expect "production example: one public origin (APP_URL)" 'name: APP_URL' "$out"

# 3. Pods: read-only root filesystems, no service account tokens, probes.
api="$(render -f "$prod" -s templates/api-deployment.yaml)"
expect "api: read-only root filesystem" "readOnlyRootFilesystem: true" "$api"
expect "api: /tmp is an emptyDir" "mountPath: /tmp" "$api"
expect "api: no service account token" "automountServiceAccountToken: false" "$api"
expect "api: readiness checks the datastores (/ready)" "path: /ready" "$api"
expect "api: liveness /health" "path: /health" "$api"
ui="$(render -f "$prod" -s templates/ui-deployment.yaml)"
expect "ui: read-only root filesystem" "readOnlyRootFilesystem: true" "$ui"
expect "ui: .next/cache is an emptyDir" "mountPath: /app/.next/cache" "$ui"
expect "ui: no service account token" "automountServiceAccountToken: false" "$ui"
expect "ui: probes /api/health" "path: /api/health" "$ui"
for f in api-migrations-job.yaml api-bootstrap-job.yaml; do
  expect "$f: no service account token" "automountServiceAccountToken: false" "$(render -f "$prod" -s "templates/$f")"
done
sensor="$(render --set api.appEnv=development --set sensor.enabled=true -s templates/sensor-deployment.yaml)"
expect "sensor: no service account token" "automountServiceAccountToken: false" "$sensor"

# 4. Credentials stay out of the migration URL (any character works).
mig="$(render -f "$prod" -s templates/api-migrations-job.yaml)"
expect "migrations: URL without credentials" '"-database=postgres://$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=$(DB_SSLMODE)"' "$mig"
expect "migrations: PGPASSWORD" 'name: PGPASSWORD' "$mig"
reject "migrations: no password in the URL" '$(DB_PASSWORD)@' "$mig"

# 5. Datastore TLS trust for private CAs.
ca=(-f "$prod" --set database.tls.ca.existingSecret=db-ca --set api.redis.ca.existingSecret=redis-ca)
api="$(render "${ca[@]}" -s templates/api-deployment.yaml)"
expect "api: PGSSLROOTCERT" "name: PGSSLROOTCERT" "$api"
expect "api: database CA mounted" "secretName: db-ca" "$api"
expect "api: REDIS_TLS_CA_FILE" "name: REDIS_TLS_CA_FILE" "$api"
expect "api: Redis CA mounted" "secretName: redis-ca" "$api"
expect "migrations: database CA mounted" "secretName: db-ca" "$(render "${ca[@]}" -s templates/api-migrations-job.yaml)"
expect "bootstrap: database CA mounted" "secretName: db-ca" "$(render "${ca[@]}" -s templates/api-bootstrap-job.yaml)"

# 6. Size presets set GOMEMLIMIT / DB_MAX_OPEN_CONNS without replacing the
#    operator's api.extraEnv; an extraEnv entry still wins.
user="$(mktemp)"; trap 'rm -f "$user"' EXIT
printf 'api:\n  extraEnv:\n    - name: LOG_LEVEL\n      value: warn\n' > "$user"
for size in small medium large; do
  api="$(render -f "$prod" -f "$user" -f "$chart/values-$size.yaml" -s templates/api-deployment.yaml)"
  expect "$size preset: GOMEMLIMIT" "name: GOMEMLIMIT" "$api"
  expect "$size preset: DB_MAX_OPEN_CONNS" "name: DB_MAX_OPEN_CONNS" "$api"
  expect "$size preset: keeps the operator's api.extraEnv" "name: LOG_LEVEL" "$api"
done
api="$(render -f "$prod" -f "$chart/values-small.yaml" --set 'api.extraEnv[0].name=GOMEMLIMIT' --set 'api.extraEnv[0].value=1GiB' -s templates/api-deployment.yaml)"
n="$(grep -c 'name: GOMEMLIMIT' <<<"$api" || true)"
if [ "$n" = 1 ]; then pass "api.extraEnv GOMEMLIMIT wins, no duplicate"; else fail "GOMEMLIMIT rendered $n times"; fi

# 7. Bundled datastores (evaluation) are pinned, never `latest`.
dev="$(render --set api.appEnv=development)"
reject "bundled datastores: no latest tag" ":latest" "$dev"

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all production checks passed"
