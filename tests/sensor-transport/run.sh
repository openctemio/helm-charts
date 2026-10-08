#!/usr/bin/env bash
# Render checks for sensor protocol v3 (OpenCTEM RFC-059): off by default; on,
# the API gets the v3 settings, the mTLS port and the sensor CA (made once by
# the chart, or yours); the bundled Caddy passes the sensor host through at
# layer 4; a dedicated Service is an alternative to the passthrough.
# Usage: tests/sensor-transport/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if [[ "$3" == *"$2"* ]]; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
render() { helm template t "$chart" --set api.appEnv=development "$@" 2>&1; }
set +e

off="$(render)"
reject "off by default: no v3 setting" "SENSOR_TRANSPORT_V3_ENABLED" "$off"
reject "off by default: no sensor CA" "sensor-ca" "$off"
reject "off by default: no mTLS port" "sensor-mtls" "$off"

https="$(render --set api.sensorTransport.enabled=true)"
expect "HTTPS binding only: v3 on" 'name: SENSOR_TRANSPORT_V3_ENABLED
              value: "true"' "$https"
reject "HTTPS binding only: no public host" "SENSOR_PUBLIC_HOST" "$https"
reject "HTTPS binding only: no mTLS port" "containerPort: 8443" "$https"
expect "the chart makes the sensor CA" "kind: Secret" "$https"
expect "the CA secret is a TLS secret" "type: kubernetes.io/tls" "$https"
expect "the CA secret is kept" "helm.sh/resource-policy: keep" "$https"
expect "the API reads the CA from the secret" "/etc/openctem/sensor-ca/tls.key" "$https"

grpc="$(render --set api.sensorTransport.enabled=true --set api.sensorTransport.publicHost=sensors.example.com:443 \
  --set gateway.mode=caddy --set gateway.host=ctem.example.com --set api.sensorTransport.gatewayPassthrough=true \
  --set 'gateway.trustedProxies={10.42.0.0/16}')"
expect "gRPC: public host" 'value: "sensors.example.com:443"' "$grpc"
expect "gRPC: mTLS listener" 'value: ":8443"' "$grpc"
expect "gRPC: container port" "containerPort: 8443" "$grpc"
expect "gRPC: Service port" "name: sensor-mtls" "$grpc"
expect "gRPC: PROXY trust defaults to the gateway's pods" 'name: SENSOR_MTLS_TRUSTED_PROXIES
              value: "10.42.0.0/16"' "$grpc"
expect "passthrough: gateway mode" 'name: OPENCTEM_SENSOR_GATEWAY
              value: passthrough' "$grpc"
expect "passthrough: sensor host name without port" 'name: SENSOR_PUBLIC_HOSTNAME
              value: "sensors.example.com"' "$grpc"
expect "passthrough: upstream is the API mTLS port" 'value: "t-openctem-api:8443"' "$grpc"
expect "passthrough: routing files mounted" "path: sensors/passthrough.wrappers" "$grpc"

np="$(render --set networkPolicy.enabled=true --set api.sensorTransport.enabled=true --set api.sensorTransport.publicHost=sensors.example.com:443   --set gateway.mode=caddy --set gateway.host=ctem.example.com --set api.sensorTransport.gatewayPassthrough=true   --set 'gateway.trustedProxies={10.42.0.0/16}')"
expect "network policy opens the mTLS port to the release" "- port: 8443" "$np"
reject "network policy: not to the world without a dedicated Service" "cidr: 0.0.0.0/0" "$np"

own="$(render --set api.sensorTransport.enabled=true --set api.sensorTransport.mtls.ca.existingSecret=my-ca)"
expect "own CA secret mounted" "secretName: my-ca" "$own"
reject "own CA: the chart makes none" "OpenCTEM sensor CA" "$own"

ded="$(render --set api.sensorTransport.enabled=true --set api.sensorTransport.publicHost=sensors.example.com:8443 \
  --set api.sensorTransport.dedicatedService.enabled=true)"
expect "dedicated Service" "name: t-openctem-api-sensors" "$ded"
expect "dedicated Service is a load balancer" "type: LoadBalancer" "$ded"

if out="$(render --set api.sensorTransport.enabled=true --set gateway.mode=caddy --set gateway.host=ctem.example.com \
  --set api.sensorTransport.gatewayPassthrough=true)"; then
  fail "passthrough without publicHost must fail"
else
  expect "passthrough without publicHost refused" "api.sensorTransport.publicHost is required" "$out"
fi

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "sensor transport render checks passed"
