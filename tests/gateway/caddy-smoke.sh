#!/usr/bin/env bash
# Runs the bundled-Caddy gateway exactly as the chart renders it (ConfigMap
# files, environment, non-root user, read-only root filesystem, dropped
# capabilities) in Docker, in front of two stub upstreams
# named like the chart's API and UI Services, and checks the routing over real
# HTTPS (TLS mode `internal`) and plain HTTP (TLS mode `http`).
# Usage: tests/gateway/caddy-smoke.sh  (needs helm, docker, curl, python3+PyYAML)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
net="octem-gw-smoke-$$"
cleanup() {
  docker rm -f "$net-api" "$net-ui" "$net-gw" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
extra_mounts=()

# Stub upstreams: answer with their own name and the client IP they were given.
# The API stub sets its own HSTS (as the API does in production); the gateway's
# HSTS is only a default, so the response must carry exactly one.
for name in api ui; do
  mkdir -p "$tmp/$name"
  hsts=""
  [ "$name" = api ] && hsts='add_header Strict-Transport-Security "max-age=63072000" always;'
  cat > "$tmp/$name/default.conf" <<EOT
server {
  listen 80;
  location / {
    default_type text/plain;
    $hsts
    return 200 "$name realip=\$http_x_real_ip\n";
  }
}
EOT
done
docker network create "$net" >/dev/null
docker run -d --name "$net-api" --network "$net" --network-alias t-openctem-api \
  -v "$tmp/api/default.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
docker run -d --name "$net-ui" --network "$net" --network-alias t-openctem-ui \
  -v "$tmp/ui/default.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null

# Render the chart and lay out what the pod would see: /etc/caddy from the
# ConfigMap items, the container env, image and security settings.
extract() { # extract <outdir> <helm args...>
  local out="$1"; shift
  helm template t "$chart" "$@" -s templates/gateway-caddy.yaml > "$out.yaml"
  python3 - "$out" "$out.yaml" <<'PY'
import os, sys, yaml
out, src = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap")
dep = next(d for d in docs if d["kind"] == "Deployment")
pod = dep["spec"]["template"]["spec"]
c = pod["containers"][0]
vol = next(v for v in pod["volumes"] if v["name"] == "config")
for item in vol["configMap"]["items"]:
    p = os.path.join(out, "etc-caddy", item["path"])
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(cm["data"][item["key"]] + "\n")
with open(os.path.join(out, "env"), "w") as f:
    for e in c["env"]:
        f.write("%s=%s\n" % (e["name"], e.get("value", "")))
psc, sc = pod["securityContext"], c["securityContext"]
args = ["--user", "%d:%d" % (psc["runAsUser"], psc["runAsGroup"])]
for s in psc.get("sysctls", []):
    args += ["--sysctl", "%s=%s" % (s["name"], s["value"])]
if sc.get("readOnlyRootFilesystem"):
    args += ["--read-only"]
for cap in sc.get("capabilities", {}).get("drop", []):
    args += ["--cap-drop", cap]
for cap in sc.get("capabilities", {}).get("add", []):
    args += ["--cap-add", cap]
if sc.get("allowPrivilegeEscalation") is False:
    args += ["--security-opt", "no-new-privileges"]
open(os.path.join(out, "args"), "w").write("\n".join(args) + "\n")
open(os.path.join(out, "image"), "w").write(c["image"] + "\n")
open(os.path.join(out, "command"), "w").write("\n".join(c["command"]) + "\n")
open(os.path.join(out, "liveness"), "w").write("\n".join(c["livenessProbe"]["exec"]["command"]) + "\n")
open(os.path.join(out, "ports"), "w").write("\n".join(str(p["containerPort"]) for p in c["ports"]) + "\n")
PY
}

start_gateway() { # start_gateway <dir> <container port>
  local dir="$1" port="$2" uid
  mapfile -t args < "$dir/args"
  mapfile -t cmd < "$dir/command"
  uid="$(awk 'prev == "--user" { split($0, a, ":"); print a[1]; exit } { prev = $0 }' "$dir/args")"
  docker rm -f "$net-gw" >/dev/null 2>&1 || true
  docker run -d --name "$net-gw" --network "$net" "${args[@]}" \
    --env-file "$dir/env" \
    -v "$dir/etc-caddy:/etc/caddy:ro" "${extra_mounts[@]}" \
    --tmpfs "/data:uid=$uid,gid=$uid" --tmpfs "/config:uid=$uid,gid=$uid" --tmpfs /tmp \
    -p "127.0.0.1::$port" \
    --entrypoint "${cmd[0]}" "$(cat "$dir/image")" "${cmd[@]:1}" >/dev/null
  sleep 2
  if [ "$(docker inspect -f '{{.State.Running}}' "$net-gw")" != true ]; then
    echo "--- gateway exited"; docker logs "$net-gw" 2>&1 | tail -30
    return 1
  fi
  hostport="$(docker port "$net-gw" "$port/tcp" | head -1 | sed 's/.*://')"
}

wait_up() { # wait_up <curl args...>
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$@"; then return 0; fi
    sleep 1
  done
  echo "--- gateway log"; docker logs "$net-gw" 2>&1 | tail -30
  return 1
}

check() { # check <description> <want prefix> <curl args...>
  local desc="$1" want="$2" got; shift 2
  got="$(curl -s -w ' %{http_code}' "$@" || true)"
  if [[ "$got" == "$want"* ]]; then pass "$desc"; else fail "$desc (want '$want', got '$got')"; fi
}

routes() { # routes <base url> <curl args...>
  local u="$1"; shift
  check "/ -> ui" "ui " "$@" "$u/"
  check "browser cookie call /api/v1/findings -> ui" "ui " "$@" -H 'Cookie: auth_token=abc' -H 'Authorization: Bearer eyJ' "$u/api/v1/findings"
  check "no credential /api/v1/findings -> ui" "ui " "$@" "$u/api/v1/findings"
  check "Bearer oct_ key -> api" "api " "$@" -H 'Authorization: Bearer oct_abc' "$u/api/v1/findings"
  check "Bearer oct_ key with session cookie -> api" "api " "$@" -H 'Cookie: auth_token=abc' -H 'Authorization: Bearer oct_abc' "$u/api/v1/findings"
  check "X-API-Key -> api" "api " "$@" -H 'X-API-Key: k' "$u/api/v1/assets"
  check "Bearer token without session cookie -> api" "api " "$@" -H 'Authorization: Bearer eyJ' "$u/api/v1/findings"
  for p in /health /openapi.yaml /docs /api/v1/ws /api/v1/agent/heartbeat /api/v2/sensor/x /api/v1/platform/x \
           /scim/v2/Users /api/v1/mcp /api/v1/webhooks/incoming/jira /api/v1/auth/saml/metadata \
           /api/v1/auth/backchannel-logout; do
    check "$p -> api" "api " "$@" "$u$p"
  done
  for p in /metrics /metrics/x /ready /debug/pprof/; do
    check "$p -> 404" " 404" "$@" "$u$p"
  done
  local got
  got="$(curl -s "$@" -H 'X-API-Key: k' -H 'X-Real-IP: 6.6.6.6' -H 'X-Forwarded-For: 6.6.6.6' "$u/api/v1/assets" || true)"
  if [[ "$got" =~ ^api\ realip=[0-9.]+$ && "$got" != *6.6.6.6* ]]; then
    pass "client IP set by the gateway, not by the client ($got)"
  else
    fail "client IP header (got '$got')"
  fi
}

common=(--set api.appEnv=development --set gateway.mode=caddy --set gateway.host=ctem.example.com
        --set "gateway.trustedProxies={10.42.0.0/16}")

# 1. TLS mode internal (the default): HTTPS on 443 only.
d="$tmp/internal"; mkdir -p "$d"
extract "$d" "${common[@]}"
if [ "$(cat "$d/ports")" = "443" ]; then pass "internal: container port 443 only"; else fail "internal: ports $(cat "$d/ports")"; fi
start_gateway "$d" 443
ca="$tmp/root.crt"
for _ in $(seq 1 30); do
  docker exec "$net-gw" cat /data/caddy/pki/authorities/local/root.crt > "$ca" 2>/dev/null && [ -s "$ca" ] && break
  sleep 1
done
if [ -s "$ca" ]; then pass "internal: root CA readable with the NOTES command"; else fail "internal: no root CA"; fi
r=(--resolve "ctem.example.com:$hostport:127.0.0.1" --cacert "$ca")
base="https://ctem.example.com:$hostport"
wait_up "${r[@]}" "$base/" && pass "internal: HTTPS verified against the internal CA" || fail "internal: HTTPS did not come up"
routes "$base" "${r[@]}"
hdrs="$(curl -s -D - -o /dev/null "${r[@]}" "$base/health" | tr -d '\r')"
if [ "$(grep -ci '^strict-transport-security:' <<<"$hdrs")" = 1 ]; then pass "internal: one HSTS header (the API's)"; else fail "internal: want exactly one HSTS header"; fi
if grep -qi '^strict-transport-security:' <(curl -s -D - -o /dev/null "${r[@]}" "$base/"); then pass "internal: HSTS default on UI responses"; else fail "internal: no HSTS on UI responses"; fi
if grep -qi '^via:' <<<"$hdrs"; then fail "internal: Via header not removed"; else pass "internal: no Via header"; fi
mapfile -t live < "$d/liveness"
if docker exec "$net-gw" "${live[@]}"; then pass "internal: liveness probe command succeeds"; else fail "internal: liveness probe fails"; fi
if docker exec "$net-gw" id -u | grep -qx 1000; then pass "internal: runs as uid 1000"; else fail "internal: not uid 1000"; fi

# 2. TLS mode http (behind a TLS proxy): port 80 only.
d="$tmp/http"; mkdir -p "$d"
extract "$d" "${common[@]}" --set gateway.caddy.tls.mode=http --set gateway.caddy.tls.allowPlainHttp=true
if [ "$(cat "$d/ports")" = "80" ]; then pass "http: container port 80 only"; else fail "http: ports $(cat "$d/ports")"; fi
start_gateway "$d" 80
base="http://127.0.0.1:$hostport"
wait_up "$base/" && pass "http: up" || fail "http: did not come up"
routes "$base"

# 3. TLS mode files: the operator's certificate from a kubernetes.io/tls Secret
#    (mounted at /certs as tls.crt / tls.key, like the chart's secret volume).
d="$tmp/files"; mkdir -p "$d" "$tmp/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=ctem.example.com \
  -addext subjectAltName=DNS:ctem.example.com \
  -keyout "$tmp/certs/tls.key" -out "$tmp/certs/tls.crt" 2>/dev/null
chmod 0644 "$tmp/certs/tls.key" "$tmp/certs/tls.crt"
extract "$d" "${common[@]}" --set gateway.caddy.tls.mode=files --set gateway.caddy.tls.files.secretName=octem-tls
extra_mounts=(-v "$tmp/certs:/certs:ro")
start_gateway "$d" 443
extra_mounts=()
r=(--resolve "ctem.example.com:$hostport:127.0.0.1" --cacert "$tmp/certs/tls.crt")
base="https://ctem.example.com:$hostport"
wait_up "${r[@]}" "$base/" && pass "files: HTTPS with the operator's certificate" || fail "files: HTTPS did not come up"
check "files: Bearer oct_ key -> api" "api " "${r[@]}" -H 'Authorization: Bearer oct_abc' "$base/api/v1/findings"
check "files: /metrics -> 404" " 404" "${r[@]}" "$base/metrics"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all gateway smoke checks passed"
