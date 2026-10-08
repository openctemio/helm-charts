#!/usr/bin/env bash
# sync-monitoring.sh: copy the OpenCTEM alert rules into the chart.
#
# monitoring.prometheusRule renders a PrometheusRule from the rules the
# docker-compose monitoring stack uses, byte for byte:
# openctemio/openctem deploy/observability/prometheus/rules/openctem.yml
# (runbooks: api/docs/operations/monitoring.md there).
#
#   scripts/sync-monitoring.sh            copy from the openctem `develop` branch
#   scripts/sync-monitoring.sh <ref>      copy from a branch, tag or commit
#
# It records the resolved commit in files/monitoring/UPSTREAM, which
# tests/monitoring/run.sh (CI) checks the copy against. Never edit the copy
# here: change the monorepo, then re-run this script.
#
# Override for tests: PLATFORM_REPO (any git URL or path).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/charts/openctem/files/monitoring"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/openctemio/openctem.git}"
ref="${1:-develop}"
src="deploy/observability/prometheus/rules/openctem.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$PLATFORM_REPO" "$ref"
sha="$(git -C "$tmp" rev-parse FETCH_HEAD)"

mkdir -p "$DEST"
git -C "$tmp" show "FETCH_HEAD:$src" > "$DEST/openctem-rules.yml"
cat > "$DEST/UPSTREAM" <<EOT
# openctem-rules.yml is a copy of openctemio/openctem $src
# at this commit. Do not edit it here: change the monorepo, then run
# scripts/sync-monitoring.sh <ref>. CI (tests/monitoring/run.sh) fails when
# the copy differs from this commit.
commit=$sha
source=$src
EOT
echo "synced $src from $ref ($sha)"
