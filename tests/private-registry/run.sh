#!/usr/bin/env bash
# Render checks for private registries: image.digest (repo:tag@digest on every
# OpenCTEM image, jobs included), global.imageRegistry (replaces the
# ghcr.io/openctemio prefix, third-party images untouched), imagePullSecrets on
# every pod, a bad digest refused, and no change when the values are unset.
# Usage: tests/private-registry/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
render() { helm template t "$chart" --set api.appEnv=development "$@" 2>&1; }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

# 1. Defaults: unchanged references, no digest.
out="$(render --set sensor.enabled=true --set console.enabled=true --set gateway.mode=caddy --set gateway.host=x.example.com --set "gateway.trustedProxies={10.42.0.0/16}")"
expect "default: api by tag" "image: \"ghcr.io/openctemio/openctem-api:" "$out"
expect "default: sensor by tag" "image: \"ghcr.io/openctemio/sensor:v" "$out"
reject "default: no digest" "@sha256:1111" "$out"
reject "default: no mirror" "registry.example.com" "$out"

# 2. Full private-registry values.
out="$(render -f "$here/values.yaml" --set api.migrations.downMigration.enabled=true --show-only templates/api-deployment.yaml \
  --show-only templates/api-migrations-job.yaml --show-only templates/api-migrations-down-job.yaml \
  --show-only templates/api-bootstrap-job.yaml --show-only templates/sensor-enrollment.yaml \
  --show-only templates/ui-deployment.yaml --show-only templates/console-deployment.yaml \
  --show-only templates/gateway-caddy.yaml --show-only templates/sensor-deployment.yaml \
  --show-only templates/sensor-seccomp-installer.yaml --show-only templates/backup-cronjob.yaml)"
d() { printf 'sha256:'; printf '%064d' 0 | tr 0 "$1"; }
expect "api" "image: \"registry.example.com/openctem/openctem-api:v0.10.1@$(d 1)\"" "$out"
expect "migrations (up and down jobs)" "registry.example.com/openctem/migrations:" "$out"
[ "$(grep -cF "migrations:v0.10.1@$(d 2)" <<<"$out")" -ge 2 ] && pass "migrations digest on up and down jobs" || fail "migrations digest on up and down jobs"
[ "$(grep -cF "openctem-api:v0.10.1@$(d 1)" <<<"$out")" -ge 3 ] && pass "api digest on deployment, bootstrap and enrollment" || fail "api digest on deployment, bootstrap and enrollment"
expect "ui" "registry.example.com/openctem/openctem-web:v0.10.1@$(d 3)" "$out"
expect "console" "registry.example.com/openctem/openctem-console:v0.10.1@$(d 4)" "$out"
expect "gateway" "registry.example.com/openctem/openctem-gateway:v0.10.1@$(d 5)" "$out"
expect "sensor" "registry.example.com/openctem/sensor:v0.23.2@$(d 6)" "$out"
reject "no ghcr.io OpenCTEM image left" "ghcr.io/openctemio" "$out"
expect "bundled postgres follows global.imageRegistry" "registry.example.com/openctem/bitnamilegacy/postgresql:" "$(render -f "$here/values.yaml")"
expect "third-party override kept" "registry.example.com/mirror/rclone:" "$out"
expect "pull secret on pods and jobs" "name: regcred" "$out"
n_pods="$(grep -cE "^\s+(image|installerImage):" <<<"$out" || true)"
n_ips="$(grep -c "imagePullSecrets:" <<<"$out" || true)"
[ "$n_ips" -ge 8 ] && pass "imagePullSecrets rendered on $n_ips pod specs" || fail "imagePullSecrets only on $n_ips pod specs ($n_pods images)"

# 3. Seccomp installer falling back to the sensor image uses the same helper.
out="$(render -f "$here/values.yaml" --show-only templates/sensor-seccomp-installer.yaml)"
expect "seccomp installer: sensor image from the mirror, by digest" "registry.example.com/openctem/sensor:v0.23.2@$(d 6)" "$out"

# 4. Mirror only (no digest), trailing slash tolerated; user repository untouched.
out="$(render --set global.imageRegistry=reg.local:5000/oc/ --show-only templates/ui-deployment.yaml)"
expect "mirror only: ui" "image: \"reg.local:5000/oc/openctem-web:" "$out"
reject "mirror only: no digest" "@sha256" "$out"
out="$(render --set global.imageRegistry=reg.local --set ui.image.repository=other.io/team/web --show-only templates/ui-deployment.yaml)"
expect "own repository kept" "image: \"other.io/team/web:" "$out"

# 5. A malformed digest is refused.
if out="$(render --set ui.image.digest=sha256:abc 2>&1)"; then fail "bad digest accepted"; else pass "bad digest refused"; fi

echo; [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
