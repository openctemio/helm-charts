#!/usr/bin/env bash
# Render checks for sensor protocol v3 (OpenCTEM RFC-059). The API serves it by
# itself (SENSOR_TRANSPORT_V3=auto): the mTLS port and the sensor CA (made once
# by the chart, or yours) are always there; mode=off is the only switch. The
# bundled Caddy routes the gRPC binding on its port 443 by the sensor ALPN id
# (alpn, the default with a layer4 image) or also by a dedicated host name
# (passthrough); a dedicated Service is the other way. The values removed in
# chart 0.18.0 fail the render.
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
refused() { # name, expected message, render args...
  local name="$1" msg="$2" out
  shift 2
  if out="$(render "$@")"; then fail "$name must fail the render"; else expect "$name refused" "$msg" "$out"; fi
}
caddy=(--set gateway.mode=caddy --set gateway.host=ctem.example.com --set 'gateway.trustedProxies={10.42.0.0/16}')
l4=(--set gateway.caddy.image.repository=registry.example.com/openctem-gateway-l4 --set gateway.caddy.image.layer4=true)
set +e

def="$(render)"
expect "default: v3 auto" 'name: SENSOR_TRANSPORT_V3
              value: "auto"' "$def"
reject "default: never the retired switch" "SENSOR_TRANSPORT_V3_ENABLED" "$def"
reject "default: public host derived by the API" "SENSOR_PUBLIC_HOST" "$def"
expect "default: mTLS listener" 'name: SENSOR_MTLS_LISTEN_ADDR
              value: ":9443"' "$def"
expect "default: container port" "containerPort: 9443" "$def"
expect "default: Service port" "name: sensor-mtls" "$def"
expect "the chart makes the sensor CA" "name: t-openctem-api-sensor-ca" "$def"
expect "the CA secret is a TLS secret" "type: kubernetes.io/tls" "$def"
expect "the CA secret is kept" "helm.sh/resource-policy: keep" "$def"
expect "the API reads the CA from the secret" "/etc/openctem/sensor-ca/tls.key" "$def"
reject "default: no PROXY trust without a routing gateway" "name: SENSOR_MTLS_TRUSTED_PROXIES" "$def"
reject "default: no dedicated Service" "t-openctem-api-sensors" "$def"

off="$(render --set api.sensorTransport.mode=off)"
expect "off: v3 off" 'name: SENSOR_TRANSPORT_V3
              value: "off"' "$off"
reject "off: no sensor CA" "sensor-ca" "$off"
reject "off: no mTLS port" "sensor-mtls" "$off"
offgw="$(render --set api.sensorTransport.mode=off "${caddy[@]}" "${l4[@]}")"
reject "off: the gateway routes no sensors" "name: OPENCTEM_SENSOR_GATEWAY" "$offgw"

stock_img=(--set gateway.caddy.image.repository=caddy --set gateway.caddy.image.tag=2.11.4-alpine --set gateway.caddy.image.layer4=false)
stock="$(render "${caddy[@]}" "${stock_img[@]}")"
reject "stock Caddy image: no layer-4 routing" "name: OPENCTEM_SENSOR_GATEWAY" "$stock"
reject "stock Caddy image: no PROXY trust" "name: SENSOR_MTLS_TRUSTED_PROXIES" "$stock"
expect "routing files mounted (all modes)" "path: sensors/alpn.wrappers" "$stock"

alpn="$(render "${caddy[@]}" "${l4[@]}")"
expect "layer4 image: alpn by default" 'name: OPENCTEM_SENSOR_GATEWAY
              value: alpn' "$alpn"
expect "alpn: upstream is the API mTLS port" 'value: "t-openctem-api:9443"' "$alpn"
reject "alpn: no sensor host name" "name: SENSOR_PUBLIC_HOSTNAME" "$alpn"
reject "alpn: public host derived from the public URL" "name: SENSOR_PUBLIC_HOST" "$alpn"
expect "alpn: PROXY trust defaults to the gateway's pods" 'name: SENSOR_MTLS_TRUSTED_PROXIES
              value: "10.42.0.0/16"' "$alpn"
expect "alpn: the gateway image" "image: \"registry.example.com/openctem-gateway-l4:" "$alpn"
own_tp="$(render "${caddy[@]}" "${l4[@]}" --set 'api.sensorTransport.mtls.trustedProxies={10.42.7.0/24}')"
expect "explicit PROXY trust wins" 'value: "10.42.7.0/24"' "$own_tp"
l4off="$(render "${caddy[@]}" "${l4[@]}" --set gateway.caddy.sensorGateway=off)"
reject "layer4 image, sensorGateway=off: no routing" "name: OPENCTEM_SENSOR_GATEWAY" "$l4off"

pt="$(render "${caddy[@]}" "${l4[@]}" --set gateway.caddy.sensorGateway=passthrough \
  --set api.sensorTransport.publicHost=sensors.example.com:443)"
expect "passthrough: gateway mode" 'name: OPENCTEM_SENSOR_GATEWAY
              value: passthrough' "$pt"
expect "passthrough: sensor host name without port" 'name: SENSOR_PUBLIC_HOSTNAME
              value: "sensors.example.com"' "$pt"
expect "passthrough: API public host" 'name: SENSOR_PUBLIC_HOST
              value: "sensors.example.com:443"' "$pt"

refused "alpn on the stock image" "needs the gateway image with the layer4 module" \
  "${caddy[@]}" "${stock_img[@]}" --set gateway.caddy.sensorGateway=alpn
dflt="$(render "${caddy[@]}")"
expect "default gateway image: the OpenCTEM gateway (layer4)" 'image: "ghcr.io/openctemio/openctem-gateway:' "$dflt"
expect "default gateway image: sensor ALPN routing on 443" 'name: OPENCTEM_SENSOR_GATEWAY
              value: alpn' "$dflt"
plain="$(render "${caddy[@]}" --set gateway.caddy.tls.mode=http --set gateway.caddy.tls.allowPlainHttp=true)"
reject "default image in tls.mode=http: no ALPN routing" "name: OPENCTEM_SENSOR_GATEWAY" "$plain"
refused "alpn in tls.mode=http" "needs a TLS mode" "${caddy[@]}" "${l4[@]}" \
  --set gateway.caddy.tls.mode=http --set gateway.caddy.tls.allowPlainHttp=true --set gateway.caddy.sensorGateway=alpn
refused "passthrough without publicHost" "api.sensorTransport.publicHost is required" \
  "${caddy[@]}" "${l4[@]}" --set gateway.caddy.sensorGateway=passthrough
refused "passthrough on the platform host name" "must name a host other than gateway.host" \
  "${caddy[@]}" "${l4[@]}" --set gateway.caddy.sensorGateway=passthrough --set api.sensorTransport.publicHost=ctem.example.com:443
refused "unknown sensorGateway" "is not one of: alpn, passthrough, off" "${caddy[@]}" --set gateway.caddy.sensorGateway=sni
refused "unknown mode" "is not one of: auto, off" --set api.sensorTransport.mode=on
refused "removed api.sensorTransport.enabled" "api.sensorTransport.enabled was removed in chart 0.18.0" \
  --set api.sensorTransport.enabled=true
refused "removed api.sensorTransport.enabled=false too" "api.sensorTransport.enabled was removed" \
  --set api.sensorTransport.enabled=false
refused "removed api.sensorTransport.gatewayPassthrough" "api.sensorTransport.gatewayPassthrough was removed" \
  --set api.sensorTransport.gatewayPassthrough=true
refused "retired env in api.extraEnv" "SENSOR_TRANSPORT_V3_ENABLED -> api.sensorTransport.mode" \
  --set 'api.extraEnv[0].name=SENSOR_TRANSPORT_V3_ENABLED' --set-string 'api.extraEnv[0].value=true'

np="$(render --set networkPolicy.enabled=true "${caddy[@]}" "${l4[@]}")"
expect "network policy opens the mTLS port to the release" "- port: 9443" "$np"
reject "network policy: not to the world without a dedicated Service" "cidr: 0.0.0.0/0" "$np"
npi="$(render --set networkPolicy.enabled=true --set gateway.mode=ingress --set gateway.host=ctem.example.com \
  --set 'gateway.trustedProxies={10.42.0.0/16}' --set api.sensorTransport.publicHost=sensors.example.com:443 \
  --set networkPolicy.ingressControllerNamespaceSelector.kubernetes\\.io/metadata\\.name=ingress-nginx)"
expect "network policy: ssl-passthrough controller reaches the mTLS port" "kubernetes.io/metadata.name: ingress-nginx" "$npi"

own="$(render --set api.sensorTransport.mtls.ca.existingSecret=my-ca)"
expect "own CA secret mounted" "secretName: my-ca" "$own"
reject "own CA: the chart makes none" "t-openctem-api-sensor-ca" "$own"

ded="$(render --set api.sensorTransport.publicHost=sensors.example.com:8443 \
  --set api.sensorTransport.dedicatedService.enabled=true --set networkPolicy.enabled=true)"
expect "dedicated Service" "name: t-openctem-api-sensors" "$ded"
expect "dedicated Service is a load balancer" "type: LoadBalancer" "$ded"
expect "dedicated Service: network policy open to sensors anywhere" "cidr: 0.0.0.0/0" "$ded"
refused "dedicated Service without publicHost" "dedicatedService needs api.sensorTransport.publicHost" \
  --set api.sensorTransport.dedicatedService.enabled=true

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "sensor transport render checks passed"
