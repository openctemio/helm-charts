#!/usr/bin/env bash
# Render checks for the least-privilege database split:
# migration Jobs connect as database.migrator (the schema owner), the API keeps
# database.auth (the DML-only role). See openctem api/docs/deployment/database-roles.md.
# Usage: tests/least-privilege/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

ext=(--set api.appEnv=development --set postgresql.enabled=false
  --set database.host=db.example --set database.auth.username=openctem_app
  --set database.auth.password=apppw)
render() { helm template t "$chart" "${ext[@]}" "$@" 2>&1; }

expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

# 1. Single-role (default): migrations use the API's credentials.
out="$(render -s templates/api-migrations-job.yaml)"
expect "single-role: migrations read DB_USER" "key: DB_USER" "$out"
reject "single-role: no migrator key" "DB_MIGRATE_USER" "$out"

# 2. Split: migrations use the migrator keys, the API does not.
split=(--set database.migrator.username=openctem_migrator --set database.migrator.password=migpw)
out="$(render "${split[@]}" -s templates/api-migrations-job.yaml)"
expect "split: migrate job reads the migrator user" "key: DB_MIGRATE_USER" "$out"
expect "split: migrate job reads the migrator password" "key: DB_MIGRATE_PASSWORD" "$out"
out="$(render "${split[@]}" --set api.migrations.downMigration.enabled=true -s templates/api-migrations-down-job.yaml)"
expect "split: down job reads the migrator user" "key: DB_MIGRATE_USER" "$out"
out="$(render "${split[@]}" -s templates/api-deployment.yaml)"
reject "split: the API never gets the migrator credentials" "DB_MIGRATE" "$out"
expect "split: the API keeps database.auth" "key: DB_USER" "$out"
out="$(render "${split[@]}" -s templates/api-db-secret.yaml)"
expect "split: created secret carries the migrator user" 'DB_MIGRATE_USER: "openctem_migrator"' "$out"

# 3. A migrator user without a password is refused.
if out="$(render --set database.migrator.username=openctem_migrator -s templates/api-db-secret.yaml)"; then
  fail "split: missing migrator password refused (render succeeded)"
else
  expect "split: missing migrator password refused" "database.migrator.password is required" "$out"
fi

# 4. An existing migrator secret is referenced, not created.
out="$(render --set database.migrator.existingSecret=pg-migrator -s templates/api-migrations-job.yaml)"
expect "existing secret: migrate job reads it" "name: pg-migrator" "$out"

# 5. The bundled dev Postgres ignores the split (it has one user).
out="$(helm template t "$chart" --set api.appEnv=development --set database.migrator.username=x --set database.migrator.password=y -s templates/api-migrations-job.yaml 2>&1)"
reject "bundled postgres: split ignored" "DB_MIGRATE_USER" "$out"

# 6. The console role (database.console): the API and bootstrap-admin get
# DB_ADMIN_USER, the migrations do not; it needs the migrator split.
console=(--set database.console.username=openctem_console --set database.console.password=conpw)
out="$(render "${split[@]}" "${console[@]}" -s templates/api-deployment.yaml)"
expect "console: the API reads the console user" "key: DB_ADMIN_USER" "$out"
expect "console: the API reads the console password" "key: DB_ADMIN_PASSWORD" "$out"
out="$(render "${split[@]}" "${console[@]}" -s templates/api-migrations-job.yaml)"
reject "console: migrations never get the console role" "DB_ADMIN" "$out"
out="$(render "${split[@]}" "${console[@]}" -s templates/api-db-secret.yaml)"
expect "console: created secret carries the console user" 'DB_ADMIN_USER: "openctem_console"' "$out"
out="$(render "${split[@]}" "${console[@]}" --set api.bootstrapAdmin.enabled=true --set api.bootstrapAdmin.email=ops@example.com --set api.bootstrapAdmin.noBackup=true -s templates/api-bootstrap-job.yaml)"
expect "console: bootstrap-admin connects as the console role" 'value: "$(DB_ADMIN_USER)"' "$out"
out="$(render "${split[@]}" -s templates/api-deployment.yaml)"
reject "no console role: the API gets no DB_ADMIN_USER" "DB_ADMIN" "$out"
if out="$(render "${console[@]}" -s templates/api-deployment.yaml)"; then
  fail "console without migrator refused (render succeeded)"
else
  expect "console without migrator refused" "database.console needs database.migrator" "$out"
fi
if out="$(render "${split[@]}" --set database.console.username=openctem_console -s templates/api-db-secret.yaml)"; then
  fail "console: missing password refused (render succeeded)"
else
  expect "console: missing password refused" "database.console.password is required" "$out"
fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all least-privilege checks passed"
