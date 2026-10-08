#!/usr/bin/env bash
# Render checks for monitoring.* (OpenCTEM api/docs/operations/monitoring.md):
# the API metrics token, the ServiceMonitor, the PrometheusRule and its rules
# copy, and the NetworkPolicy opening for Prometheus.
# Usage: tests/monitoring/run.sh  (needs helm and git; dependencies built)
# Override for tests: PLATFORM_REPO (any git URL or path), CHART.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/openctemio/openctem.git}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

render() { helm template t "$chart" --set api.appEnv=development "$@" 2>&1; }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

# 1. Off by default: no token, no secret, no monitoring objects.
out="$(render)"
reject "default: the API gets no METRICS_TOKEN" "name: METRICS_TOKEN" "$out"
reject "default: no metrics secret" "t-openctem-api-metrics" "$out"
reject "default: no ServiceMonitor" "kind: ServiceMonitor" "$out"
reject "default: no PrometheusRule" "kind: PrometheusRule" "$out"

# 2. Enabled: a generated token, wired into the API and the ServiceMonitor.
on=(--set monitoring.enabled=true --set monitoring.serviceMonitor.enabled=true --set monitoring.prometheusRule.enabled=true)
out="$(render "${on[@]}")"
expect "enabled: the API reads METRICS_TOKEN" "name: METRICS_TOKEN" "$out"
expect "enabled: chart-created token secret" "name: t-openctem-api-metrics" "$out"
expect "enabled: ServiceMonitor scrapes /metrics" "path: /metrics" "$out"
expect "enabled: ServiceMonitor sends the token" "type: Bearer" "$out"
expect "enabled: job label the rules use" "replacement: openctem-api" "$out"
expect "enabled: PrometheusRule" "kind: PrometheusRule" "$out"
expect "enabled: the Kubernetes target-down rule" "alert: ApiTargetDown" "$out"
expect "enabled: an API rule from the synced file" "alert: ApiPanics" "$out"
reject "enabled: compose-only groups are left out" "alert: HostDiskLow" "$out"
# shellcheck disable=SC2016 # the literal Prometheus template marker
expect "enabled: Prometheus template markers kept for Prometheus" '{{ $value | humanizePercentage }}' "$out"

# 3. existingSecret: nothing created, the API and ServiceMonitor use it.
out="$(render "${on[@]}" --set monitoring.existingSecret=ops-metrics --set monitoring.metricsTokenKey=token)"
reject "existingSecret: no chart-created secret" "name: t-openctem-api-metrics" "$out"
expect "existingSecret: referenced by name" "name: ops-metrics" "$out"
expect "existingSecret: referenced by key" "key: token" "$out"

# 4. Refusals.
out="$(render --set monitoring.serviceMonitor.enabled=true || true)"
expect "a ServiceMonitor without the token is refused" "needs monitoring.enabled=true" "$out"
out="$(render --set monitoring.enabled=true --set monitoring.prometheusRule.enabled=true --set "monitoring.prometheusRule.groups={openctem-api,missing}" || true)"
expect "an unknown rule group is refused" "does not have" "$out"

# 5. NetworkPolicy: Prometheus may reach the API port, from the selected namespace.
out="$(render "${on[@]}" --set networkPolicy.enabled=true --set monitoring.prometheusNamespaceSelector.name=monitoring -s templates/networkpolicy.yaml)"
expect "networkPolicy: Prometheus allowed" "Prometheus scrapes /metrics" "$out"
expect "networkPolicy: from the monitoring namespace" "name: monitoring" "$out"

# 6. The rules file is the monorepo's, unchanged (files/monitoring/UPSTREAM).
upstream="$chart/files/monitoring/UPSTREAM"
commit="$(sed -n 's/^commit=//p' "$upstream")"
src="$(sed -n 's/^source=//p' "$upstream")"
if [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "$PLATFORM_REPO" "$commit"
  if git -C "$tmp" show "FETCH_HEAD:$src" | cmp -s - "$chart/files/monitoring/openctem-rules.yml"; then
    pass "files/monitoring/openctem-rules.yml is openctem@${commit:0:12} $src"
  else
    fail "files/monitoring/openctem-rules.yml differs from openctem@${commit:0:12} $src (run scripts/sync-monitoring.sh <ref>)"
  fi
else
  fail "$upstream: commit=$commit is not a full commit id"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all monitoring checks passed"
