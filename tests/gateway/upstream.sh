#!/usr/bin/env bash
# upstream.sh: the chart's gateway files are the OpenCTEM gateway's, unchanged.
#
# files/gateway/UPSTREAM names an openctemio/openctem commit and the files
# copied from its api/deploy/gateway/ (scripts/sync-gateway.sh writes both).
# This fails when a copy differs from that commit, so a hand edit here, or a
# copy that was not re-synced, cannot drift from the monorepo's generated
# planes.caddy or its access-log redaction.
#
# LATEST_REF=develop also warns (GitHub annotation, exit 0) when the pinned
# copies are behind that ref.
#
# Override for tests: PLATFORM_REPO (any git URL or path), CHART_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_DIR="${CHART_DIR:-$ROOT/charts/openctem}"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/openctemio/openctem.git}"
upstream="$CHART_DIR/files/gateway/UPSTREAM"

commit="$(sed -n 's/^commit=//p' "$upstream")"
read -r -a files <<<"$(sed -n 's/^files=//p' "$upstream")"
if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FAIL - $upstream: commit=$commit is not a full commit id"
  exit 1
fi
for want in Caddyfile planes.caddy entrypoint.sh; do
  if [[ " ${files[*]} " != *" $want "* ]]; then
    echo "FAIL - $upstream: $want is not in files="
    exit 1
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$PLATFORM_REPO" "$commit"

fails=0
for f in "${files[@]}"; do
  if git -C "$tmp" show "FETCH_HEAD:api/deploy/gateway/$f" | cmp -s - "$CHART_DIR/files/gateway/$f"; then
    echo "ok   - files/gateway/$f is openctem@${commit:0:12} api/deploy/gateway/$f"
  else
    echo "FAIL - files/gateway/$f differs from openctem@${commit:0:12} api/deploy/gateway/$f"
    git -C "$tmp" show "FETCH_HEAD:api/deploy/gateway/$f" | diff - "$CHART_DIR/files/gateway/$f" | head -20 || true
    fails=$((fails + 1))
  fi
done
if [ "$fails" -ne 0 ]; then
  echo "Run scripts/sync-gateway.sh <ref> instead of editing the copies."
  exit 1
fi

# Advisory: is the pinned commit behind the monorepo? (A warning, not a
# failure: the chart may deliberately pin a release while develop moves on.)
if [ -n "${LATEST_REF:-}" ]; then
  git -C "$tmp" fetch -q --depth 1 "$PLATFORM_REPO" "$LATEST_REF"
  for f in "${files[@]}"; do
    if ! git -C "$tmp" show "FETCH_HEAD:api/deploy/gateway/$f" | cmp -s - "$CHART_DIR/files/gateway/$f"; then
      echo "::warning file=charts/openctem/files/gateway/$f::files/gateway/$f differs from openctem $LATEST_REF; run scripts/sync-gateway.sh $LATEST_REF"
    fi
  done
fi
