#!/usr/bin/env bash
# sync-gateway.sh: copy the OpenCTEM gateway files into the chart.
#
# The bundled Caddy (gateway.mode=caddy) runs the docker-compose gateway's
# files from openctemio/openctem `api/deploy/gateway/`, byte for byte:
#   Caddyfile     routing, access-log redaction, headers
#   planes.caddy  the API planes, GENERATED there from the API's plane table
#                 (OpenCTEM RFC-041); the chart's Ingress/HTTPRoute path lists
#                 are read from it at render time
#   entrypoint.sh TLS-mode validation
# The TLS mode files (files/gateway/modes/) stay chart-owned: the chart serves
# port 80 only in modes acme and http, so its internal/files modes do not
# import the compose file's port-80 redirect.
#
#   scripts/sync-gateway.sh            copy from the openctem `develop` branch
#   scripts/sync-gateway.sh <ref>      copy from a branch, tag or commit
#
# It records the resolved commit in files/gateway/UPSTREAM, which
# tests/gateway/upstream.sh (CI) checks the copies against. Never edit the
# copies here: change the monorepo, then re-run this script.
#
# Override for tests: PLATFORM_REPO (any git URL or path).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/charts/openctem/files/gateway"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/openctemio/openctem.git}"
ref="${1:-develop}"
files=(Caddyfile planes.caddy entrypoint.sh)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$PLATFORM_REPO" "$ref"
sha="$(git -C "$tmp" rev-parse FETCH_HEAD)"

for f in "${files[@]}"; do
  git -C "$tmp" show "FETCH_HEAD:api/deploy/gateway/$f" > "$DEST/$f"
done
chmod 0644 "$DEST/Caddyfile" "$DEST/planes.caddy"

cat > "$DEST/UPSTREAM" <<EOF
# The gateway files listed below are copies of openctemio/openctem
# api/deploy/gateway at this commit. Do not edit them here: change the
# monorepo, then run scripts/sync-gateway.sh <ref>. CI
# (tests/gateway/upstream.sh) fails when a copy differs from this commit.
commit=$sha
files=${files[*]}
EOF
echo "synced ${files[*]} from $ref ($sha)"
