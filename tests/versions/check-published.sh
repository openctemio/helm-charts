#!/usr/bin/env bash
# check-published.sh: do the chart's default image tags exist?
# (openctemio/openctem api/docs/rfcs/RFC-037 §3.5)
#
#   tests/versions/check-published.sh            warn (GitHub annotation) and exit 0
#   STRICT=1 tests/versions/check-published.sh   exit 1 when a tag is missing
#
# appVersion is the default tag of the API, web and migrations images, so it
# must be a released OpenCTEM tag (vX.Y.Z on openctemio/openctem); the bundled
# sensor's default tag must be a released sensor tag. Charts 0.5.0 to 0.10.0
# shipped appVersion v0.9.0 before v0.9.0 was tagged, so a default install
# pulled images that did not exist. Release tags are read with git ls-remote:
# no registry credentials needed.
#
# Overrides for tests: CHART_DIR, PLATFORM_REPO, SENSOR_REPO (any git URL or path).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_DIR="${CHART_DIR:-$ROOT/charts/openctem}"
PLATFORM_REPO="${PLATFORM_REPO:-https://github.com/openctemio/openctem.git}"
SENSOR_REPO="${SENSOR_REPO:-https://github.com/openctemio/sensor.git}"
STRICT="${STRICT:-0}"

app="$(sed -nE 's/^appVersion:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$CHART_DIR/Chart.yaml")"
# The sensor's default tag: the first `tag:` under `sensor:` -> `image:` in values.yaml.
sensor="$(awk '
  /^sensor:/ { in_sensor = 1; next }
  in_sensor && /^[^[:space:]#]/ { in_sensor = 0 }
  in_sensor && /^  image:/ { in_image = 1; next }
  in_image && /^  [^[:space:]#]/ { in_image = 0 }
  in_sensor && in_image && /^    tag:/ { gsub(/["[:space:]]/, "", $2); print $2; exit }
' FS=':' "$CHART_DIR/values.yaml")"

missing=0
check() { # what repo tag
  local what="$1" repo="$2" tag="$3"
  if [[ -z "$tag" ]]; then
    echo "::error::$what: no default tag found in the chart"
    missing=$((missing + 1))
    return
  fi
  if git ls-remote --exit-code --tags "$repo" "refs/tags/$tag" >/dev/null 2>&1; then
    echo "ok: $what $tag is released"
  else
    local level=warning
    [[ "$STRICT" == 1 ]] && level=error
    echo "::$level::$what $tag is not a released tag of $repo: a default install pulls images that do not exist. Point it at a released tag, or release it first."
    missing=$((missing + 1))
  fi
}

check "appVersion (API, web, migrations images)" "$PLATFORM_REPO" "$app"
check "sensor.image.tag" "$SENSOR_REPO" "$sensor"

if [[ $missing -gt 0 && "$STRICT" == 1 ]]; then
  exit 1
fi
exit 0
