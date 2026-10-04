#!/usr/bin/env bash
# Render checks for the single-port gateway (chart 0.7.0): gateway.mode
# ingress | httpRoute | caddy, the API/UI settings it implies, the refusals,
# and that the chart's API path list is files/gateway/planes.caddy's.
# Usage: tests/gateway/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# Substring checks (a pattern may span several lines).
expect() { # expect <description> <pattern> <output>
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
reject() { # reject <description> <pattern> <output>
  if [[ "$3" == *"$2"* ]]; then fail "$1 (unexpected: $2)"; else pass "$1"; fi
}
refuse() { # refuse <description> <message> <helm args...>
  local desc="$1" msg="$2" out; shift 2
  if out="$(render "$@")"; then
    fail "$desc: render must fail"
  else
    expect "$desc" "$msg" "$out"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$chart" "$tmp/chart"
# helm template does not print NOTES.txt; render it into a ConfigMap.
cat > "$tmp/chart/templates/zz-notes.yaml" <<'EOT'
apiVersion: v1
kind: ConfigMap
metadata:
  name: zz-rendered-notes
data:
  notes: |
{{ include (print $.Template.BasePath "/NOTES.txt") . | indent 4 }}
EOT
render() { helm template t "$tmp/chart" "$@" 2>&1; }
only() { # only <template> <helm args...>: one template's output
  local t="$1"; shift
  helm template t "$tmp/chart" -s "templates/$t" "$@" 2>&1
}

DEV=(--set api.appEnv=development)
GW=("${DEV[@]}" --set gateway.host=ctem.example.com --set "gateway.trustedProxies={10.42.0.0/16,10.43.0.0/16}")

# Route helpers: "<path> <pathType> -> <service>" lines from an Ingress, and
# "<type> <path> [header] -> <service>" from an HTTPRoute.
ingress_routes() {
  awk '
    /- path:/      { p = $3 }
    /pathType:/    { t = $2 }
    /name: t-openctem-(api|ui)$/ && p != "" { print p, t, "->", $2; p = "" }
  '
}

# 0. The chart's API paths are planes.caddy's (compose and chart route alike):
#    every path of the @plane_* matchers, and nothing else.
caddy_paths="$(grep -E '^[[:space:]]*@plane_[a-z]+ path ' "$chart/files/gateway/planes.caddy" \
  | sed -E 's/.*@plane_[a-z]+ path //' | tr ' ' '\n' | grep -v '/\*$' | sort -u)"
chart_paths="$(only gateway-ingress.yaml "${GW[@]}" --set gateway.mode=ingress \
  | ingress_routes | awk '$4 == "t-openctem-api" { print $1 }' | sort -u)"
if [ -n "$caddy_paths" ] && [ "$caddy_paths" = "$chart_paths" ]; then
  pass "API path list is files/gateway/planes.caddy's"
else
  fail "API path list differs from files/gateway/planes.caddy"
  diff <(echo "$caddy_paths") <(echo "$chart_paths") || true
fi
route_paths="$(only gateway-httproute.yaml "${GW[@]}" --set gateway.mode=httpRoute \
  | awk '/type: PathPrefix/ { getline; print $2 }' | grep -vx '/' | grep -vx '/api' | sort -u)"
if [ "$caddy_paths" = "$route_paths" ]; then
  pass "HTTPRoute API paths are files/gateway/planes.caddy's"
else
  fail "HTTPRoute API paths differ from files/gateway/planes.caddy"
  diff <(echo "$caddy_paths") <(echo "$route_paths") || true
fi

# 1. Default (mode none): nothing gateway-related is rendered or set.
out="$(render "${DEV[@]}")"
reject "default: no gateway objects" "app.kubernetes.io/component: gateway" "$out"
reject "default: UI does not trust proxy headers" "TRUST_PROXY_HEADERS" "$out"
reject "default: no SERVER_TRUSTED_PROXIES" "SERVER_TRUSTED_PROXIES" "$out"
reject "default: no CORS_ALLOWED_ORIGINS" "CORS_ALLOWED_ORIGINS" "$out"
reject "default: no APP_URL" "name: APP_URL" "$out"
reject "default: no gateway notes" "Gateway: one entry point" "$out"

# 2. Refusals.
refuse "unknown mode fails" 'gateway.mode="nginx" is not supported' "${GW[@]}" --set gateway.mode=nginx
refuse "ingress without host fails" "gateway.mode=ingress needs gateway.host" \
  "${DEV[@]}" --set gateway.mode=ingress --set "gateway.trustedProxies={10.42.0.0/16}"
refuse "ingress without trustedProxies fails" "gateway.mode=ingress needs gateway.trustedProxies" \
  "${DEV[@]}" --set gateway.mode=ingress --set gateway.host=ctem.example.com
refuse "caddy without trustedProxies fails" "gateway.mode=caddy needs gateway.trustedProxies" \
  "${DEV[@]}" --set gateway.mode=caddy --set gateway.host=ctem.example.com
refuse "caddy http without allowPlainHttp fails" "confirm with gateway.caddy.tls.allowPlainHttp=true" \
  "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=http
refuse "caddy acme without email fails" "needs gateway.caddy.tls.acme.email" \
  "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=acme
refuse "caddy files without secret fails" "needs gateway.caddy.tls.files.secretName" \
  "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=files
refuse "caddy unknown tls mode fails" 'gateway.caddy.tls.mode="selfsigned" is not supported' \
  "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=selfsigned
refuse "caddy port 80 without acme/http fails" "port 80 is served only in tls.mode=acme" \
  "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.service.http.enabled=true

# 3. API and UI settings for any gateway mode.
out="$(only api-deployment.yaml "${GW[@]}" --set gateway.mode=ingress)"
expect "api: SERVER_TRUSTED_PROXIES" 'name: SERVER_TRUSTED_PROXIES
              value: 10.42.0.0/16,10.43.0.0/16' "$out"
expect "api: CORS_ALLOWED_ORIGINS" 'name: CORS_ALLOWED_ORIGINS
              value: https://ctem.example.com' "$out"
expect "api: APP_URL" 'name: APP_URL
              value: https://ctem.example.com' "$out"
expect "api: SMTP_BASE_URL" 'name: SMTP_BASE_URL
              value: https://ctem.example.com' "$out"
out="$(only api-deployment.yaml "${GW[@]}" --set gateway.mode=ingress --set gateway.publicUrl=https://ctem.example.com:8443/)"
expect "api: publicUrl override" 'value: https://ctem.example.com:8443' "$out"
reject "api: publicUrl trailing slash dropped" 'value: https://ctem.example.com:8443/' "$out"
out="$(only api-deployment.yaml "${GW[@]}" --set gateway.mode=ingress \
  --set 'api.extraEnv[0].name=CORS_ALLOWED_ORIGINS' --set 'api.extraEnv[0].value=https://other.example.com')"
expect "api: extraEnv wins" 'value: https://other.example.com' "$out"
if [ "$(grep -c 'name: CORS_ALLOWED_ORIGINS' <<<"$out")" = 1 ]; then pass "api: no duplicate env name"; else fail "api: duplicate CORS_ALLOWED_ORIGINS"; fi
out="$(only api-deployment.yaml "${DEV[@]}" --set 'gateway.trustedProxies={10.0.0.0/8}')"
expect "api: trustedProxies alone sets SERVER_TRUSTED_PROXIES" "value: 10.0.0.0/8" "$out"
reject "api: no origin without a gateway mode" "CORS_ALLOWED_ORIGINS" "$out"
out="$(only ui-deployment.yaml "${GW[@]}" --set gateway.mode=caddy)"
expect "ui: TRUST_PROXY_HEADERS" 'name: TRUST_PROXY_HEADERS
              value: "true"' "$out"

# 4. mode ingress.
out="$(only gateway-ingress.yaml "${GW[@]}" --set gateway.mode=ingress \
  --set gateway.ingress.className=nginx --set gateway.ingress.tls.clusterIssuer=letsencrypt-prod)"
routes="$(ingress_routes <<<"$out")"
expect "ingress: one host" 'host: "ctem.example.com"' "$out"
expect "ingress: class" "ingressClassName: nginx" "$out"
expect "ingress: TLS secret" "secretName: t-openctem-gateway-tls" "$out"
expect "ingress: cert-manager annotation" "cert-manager.io/cluster-issuer: letsencrypt-prod" "$out"
for r in "/api/v1/agent Prefix" "/api/v2/sensor Prefix" "/api/v1/validation/evidence Prefix" "/scim/v2 Prefix" \
         "/api/v1/mcp Prefix" "/hooks Prefix" "/api/v1/webhooks/incoming Prefix" "/api/v1/auth/saml Prefix" \
         "/api/v1/auth/backchannel-logout Prefix" "/api/v1/ws Prefix" "/health Prefix" \
         "/openapi.yaml Prefix" "/docs Prefix"; do
  expect "ingress: $r -> api" "$r -> t-openctem-api" "$routes"
done
# The stale protocol-v0 rule is gone (OpenCTEM RFC-041): the API serves none of it.
reject "ingress: no /api/v1/platform" "/api/v1/platform " "$routes"
reject "ingress: no Exact paths" " Exact -> " "$routes"
expect "ingress: / -> ui" "/ Prefix -> t-openctem-ui" "$routes"
reject "ingress: no /api catch-all to the api" "/api Prefix -> t-openctem-api" "$routes"
for p in /metrics /ready /debug; do
  reject "ingress: $p not routed" "$p " "$routes"
done
if [ "$(grep -c -- '-> t-openctem-ui' <<<"$routes")" = 1 ]; then pass "ingress: only / goes to the ui"; else fail "ingress: ui routes: $routes"; fi
out="$(only gateway-ingress.yaml "${GW[@]}" --set gateway.mode=ingress --set gateway.ingress.tls.enabled=false)"
reject "ingress: tls disabled" "tls:" "$out"
out="$(render "${GW[@]}" --set gateway.mode=ingress)"
expect "ingress: NOTES limitation" "A plain Ingress cannot match headers" "$out"
reject "ingress: no caddy objects" "name: t-openctem-gateway-data" "$out"
reject "ingress: no HTTPRoute" "kind: HTTPRoute" "$out"

# 5. mode httpRoute.
out="$(only gateway-httproute.yaml "${GW[@]}" --set gateway.mode=httpRoute)"
expect "httpRoute: hostname" '- "ctem.example.com"' "$out"
expect "httpRoute: parentRef" "sectionName: https" "$out"
expect "httpRoute: prefix /health" 'type: PathPrefix
            value: /health' "$out"
reject "httpRoute: no Exact paths" "type: Exact" "$out"
expect "httpRoute: prefix /api/v2/sensor" 'type: PathPrefix
            value: /api/v2/sensor' "$out"
expect "httpRoute: oct_ bearer header match" 'headers:
            - type: RegularExpression
              name: Authorization
              value: "^Bearer oct_.*"' "$out"
expect "httpRoute: X-API-Key header match" 'name: X-API-Key' "$out"
expect "httpRoute: header rules -> api" 'value: ".*"
      backendRefs:
        - name: t-openctem-api' "$out"
expect "httpRoute: / -> ui" 'value: /
      backendRefs:
        - name: t-openctem-ui' "$out"
reject "httpRoute: /metrics not routed" "value: /metrics" "$out"
reject "httpRoute: no /api catch-all without headers" 'value: /api
      backendRefs' "$out"
out="$(only gateway-httproute.yaml "${GW[@]}" --set gateway.mode=httpRoute --set gateway.httpRoute.apiKeyHeaderRouting=false)"
reject "httpRoute: header routing can be turned off" "X-API-Key" "$out"

# 6. mode caddy, TLS internal (default).
out="$(only gateway-caddy.yaml "${GW[@]}" --set gateway.mode=caddy)"
svc="$(awk '/^kind: Service$/,/^---/' <<<"$out")"
expect "caddy: image pinned" 'image: "caddy:2.11.4-alpine"' "$out"
expect "caddy: service LoadBalancer" "type: LoadBalancer" "$svc"
expect "caddy: service 443" 'name: https
      port: 443
      targetPort: https' "$svc"
reject "caddy: service has no port 80" "port: 80" "$svc"
for p in 2019 8080 3000 9090 2345; do reject "caddy: service does not expose $p" "port: $p" "$svc"; done
expect "caddy: keeps client IP" "externalTrafficPolicy: Local" "$svc"
expect "caddy: TLS mode env" 'name: OPENCTEM_TLS_MODE
              value: "internal"' "$out"
expect "caddy: hostname env" 'name: OPENCTEM_HOSTNAME
              value: "ctem.example.com"' "$out"
expect "caddy: API upstream" 'name: OPENCTEM_API_UPSTREAM
              value: "t-openctem-api:80"' "$out"
expect "caddy: UI upstream" 'name: OPENCTEM_WEB_UPSTREAM
              value: "t-openctem-ui:80"' "$out"
expect "caddy: plain HTTP not allowed" 'name: OPENCTEM_ALLOW_PLAIN_HTTP
              value: "false"' "$out"
expect "caddy: Caddyfile in ConfigMap" "import planes.caddy" "$out"
expect "caddy: planes.caddy in ConfigMap" "@plane_sensor path" "$out"
expect "caddy: planes.caddy mounted" 'key: planes.caddy
                path: planes.caddy' "$out"
expect "caddy: mode files mapped" "path: modes/internal.global" "$out"
expect "caddy: entrypoint" 'command: ["/bin/sh", "/etc/caddy/entrypoint.sh"]' "$out"
expect "caddy: PVC" "kind: PersistentVolumeClaim" "$out"
expect "caddy: PVC kept on uninstall" "helm.sh/resource-policy: keep" "$out"
expect "caddy: /data on the PVC" "claimName: t-openctem-gateway-data" "$out"
expect "caddy: Recreate" "type: Recreate" "$out"
expect "caddy: non-root" "runAsNonRoot: true" "$out"
expect "caddy: read-only root" "readOnlyRootFilesystem: true" "$out"
expect "caddy: only NET_BIND_SERVICE" 'capabilities:
              add:
              - NET_BIND_SERVICE
              drop:
              - ALL' "$out"
reject "caddy: no /certs in internal mode" "mountPath: /certs" "$out"
reject "caddy: no ACME env in internal mode" "name: ACME_EMAIL" "$out"
expect "caddy: config checksum" "checksum/config:" "$out"
diff <(sed -n '/^  Caddyfile: |-$/,/^  planes.caddy: |-$/p' <<<"$out" | sed '1d;$d' | sed 's/^    //' | grep -v '^[[:space:]]*$') \
  <(grep -v '^[[:space:]]*$' "$chart/files/gateway/Caddyfile") >/dev/null \
  && pass "caddy: ConfigMap Caddyfile is files/gateway/Caddyfile verbatim" \
  || fail "caddy: ConfigMap Caddyfile differs from files/gateway/Caddyfile"
diff <(sed -n '/^  planes.caddy: |-$/,/^  entrypoint.sh: |-$/p' <<<"$out" | sed '1d;$d' | sed 's/^    //' | grep -v '^[[:space:]]*$') \
  <(grep -v '^[[:space:]]*$' "$chart/files/gateway/planes.caddy") >/dev/null \
  && pass "caddy: ConfigMap planes.caddy is files/gateway/planes.caddy verbatim" \
  || fail "caddy: ConfigMap planes.caddy differs from files/gateway/planes.caddy"
out="$(render "${GW[@]}" --set gateway.mode=caddy)"
expect "caddy: NOTES root CA command" "exec deploy/t-openctem-gateway -- cat /data/caddy/pki/authorities/local/root.crt" "$out"
expect "caddy: NOTES URL" "URL: https://ctem.example.com" "$out"
expect "caddy: NOTES trusted proxies" "client-IP headers only from: 10.42.0.0/16,10.43.0.0/16" "$out"
reject "caddy: no plain-http warning" "WARNING: plain HTTP (gateway.caddy" "$out"
reject "caddy: no Ingress" "kind: Ingress" "$out"

# 7. caddy TLS modes.
out="$(only gateway-caddy.yaml "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=acme \
  --set gateway.caddy.tls.acme.email=ops@example.com --set gateway.caddy.service.http.enabled=true)"
svc="$(awk '/^kind: Service$/,/^---/' <<<"$out")"
expect "acme: email" 'value: "ops@example.com"' "$out"
expect "acme: CA" "acme-v02.api.letsencrypt.org" "$out"
expect "acme: service 443" "port: 443" "$svc"
expect "acme: optional service 80" 'name: http
      port: 80' "$svc"

out="$(only gateway-caddy.yaml "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=files \
  --set gateway.caddy.tls.files.secretName=octem-tls)"
expect "files: secret mounted at /certs" "mountPath: /certs" "$out"
expect "files: secret name" "secretName: octem-tls" "$out"
expect "files: keys mapped" 'key: tls.crt
                path: tls.crt' "$out"
expect "files: env" 'name: TLS_CERT_FILE' "$out"

out="$(only gateway-caddy.yaml "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=http \
  --set gateway.caddy.tls.allowPlainHttp=true --set gateway.caddy.service.type=ClusterIP \
  --set "gateway.caddy.frontProxies={10.0.0.0/8,192.168.0.0/16}")"
svc="$(awk '/^kind: Service$/,/^---/' <<<"$out")"
expect "http: service port 80" 'name: http
      port: 80' "$svc"
reject "http: no 443" "port: 443" "$svc"
reject "http: no externalTrafficPolicy on ClusterIP" "externalTrafficPolicy" "$svc"
expect "http: allowed" 'name: OPENCTEM_ALLOW_PLAIN_HTTP
              value: "true"' "$out"
expect "http: front proxies (space-separated)" 'value: "10.0.0.0/8 192.168.0.0/16"' "$out"
out="$(render "${DEV[@]}" --set gateway.mode=caddy --set gateway.caddy.tls.mode=http \
  --set gateway.caddy.tls.allowPlainHttp=true --set gateway.publicUrl=https://ctem.example.com \
  --set "gateway.trustedProxies={10.42.0.0/16}")"
expect "http: host optional with publicUrl" "URL: https://ctem.example.com" "$out"
expect "http: NOTES warning" "WARNING: plain HTTP (gateway.caddy.tls.mode=http)" "$out"
expect "http: NOTES front proxies warning" "gateway.caddy.frontProxies is empty" "$out"

out="$(render "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.persistence.enabled=false)"
reject "no persistence: no PVC" "name: t-openctem-gateway-data" "$out"
expect "no persistence: emptyDir /data" 'name: data
          emptyDir: {}' "$out"
expect "no persistence: NOTES warning" "/data is an emptyDir" "$out"
out="$(only gateway-caddy.yaml "${GW[@]}" --set gateway.mode=caddy --set gateway.caddy.persistence.existingClaim=my-claim)"
reject "existingClaim: no PVC" "name: t-openctem-gateway-data" "$out"
expect "existingClaim: used" "claimName: my-claim" "$out"

# 8. NetworkPolicy.
out="$(only networkpolicy.yaml "${GW[@]}" --set gateway.mode=caddy --set networkPolicy.enabled=true)"
gwnp="$(awk '/name: t-openctem-gateway-allow-ingress/,/^---/' <<<"$out")"
uinp="$(awk '/name: t-openctem-ui-allow-ingress/,/^---/' <<<"$out")"
expect "netpol caddy: gateway 443 open" "port: 443" "$gwnp"
reject "netpol caddy: gateway 80 closed (internal TLS)" "port: 80" "$gwnp"
expect "netpol caddy: ui from the gateway" "app.kubernetes.io/component: gateway" "$uinp"
reject "netpol caddy: ui not open to every namespace" "namespaceSelector: {}" "$uinp"
out="$(only networkpolicy.yaml "${GW[@]}" --set gateway.mode=ingress --set networkPolicy.enabled=true \
  --set networkPolicy.ingressControllerNamespaceSelector.kubernetes\\.io/metadata\\.name=ingress-nginx)"
apinp="$(awk '/name: t-openctem-api-allow-ingress/,/^---/' <<<"$out")"
expect "netpol ingress: controller -> api:8080" "kubernetes.io/metadata.name: ingress-nginx" "$apinp"
reject "netpol ingress: no gateway policy" "t-openctem-gateway-allow-ingress" "$out"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all gateway checks passed"
