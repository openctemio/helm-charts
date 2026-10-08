#!/usr/bin/env bash
# Schema checks: render the chart with representative values and validate
# every manifest against the Kubernetes API schemas (kubeconform, strict:
# unknown fields fail). CRDs without a published schema (ServiceMonitor,
# PrometheusRule, HTTPRoute) are skipped.
# Usage: tests/kubeconform/run.sh  (needs helm, kubeconform; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
k8s="${KUBERNETES_VERSION:-1.34.0}"
fails=0

check() { # name helm-args...
  local name="$1"; shift
  if helm template t "$chart" "$@" | kubeconform -strict -summary -kubernetes-version "$k8s" -ignore-missing-schemas; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"; fails=$((fails + 1))
  fi
}

check "dev/eval defaults" --set api.appEnv=development
check "sensor (pairing)" --set api.appEnv=development --set sensor.enabled=true
check "sensor (API key, local policy, outbox volume), NetworkPolicy, monitoring" \
  --set api.appEnv=development --set sensor.enabled=true --set sensor.apiKey=octs_test \
  --set sensor.localPolicy.enabled=true --set sensor.outbox.persistence.enabled=true \
  --set networkPolicy.enabled=true --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true --set monitoring.token=0123456789abcdef0123456789abcdef
check "gateway caddy" --set api.appEnv=development --set gateway.mode=caddy --set gateway.host=openctem.example.com --set "gateway.trustedProxies={10.244.0.0/16}"
check "production values" -f "$chart/values-production.yaml"

if [[ $fails -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all kubeconform checks passed"
