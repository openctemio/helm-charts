#!/usr/bin/env bash
# Render checks for the off-cluster backup CronJob (backup.*): off by default,
# refuses to render without the storage Secret, keeps database and storage
# credentials in separate containers, and honours the dedicated database Secret.
# Usage: tests/backup/run.sh  (needs helm; dependencies built)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="${CHART:-$here/../../charts/openctem}"
fails=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

base=(--set api.appEnv=development)
render() { helm template t "$chart" "${base[@]}" "$@" 2>&1; }
on=(--set backup.enabled=true --set backup.rclone.existingSecret=offsite)

# 1. Off by default: nothing is rendered.
out="$(render)"
reject "default: no backup CronJob" "kind: CronJob" "$out"

# 2. Enabled without the storage Secret: refuses.
out="$(render --set backup.enabled=true || true)"
expect "enabled without a Secret is refused" "backup.rclone.existingSecret" "$out"

# 3. Enabled: a CronJob with two steps.
out="$(render "${on[@]}" -s templates/backup-cronjob.yaml)"
expect "CronJob rendered" "kind: CronJob" "$out"
expect "schedule" 'schedule: "17 2 * * *"' "$out"
expect "never two runs at once" "concurrencyPolicy: Forbid" "$out"
expect "dump step is an init container" "initContainers:" "$out"
expect "dump checks the dump is readable" "pg_restore --list" "$out"
expect "upload goes through the crypt remote" 'value: "openctem-crypt:openctem"' "$out"
expect "no deletion by default" 'name: RETENTION_DAYS' "$out"
expect "retention default 0" 'value: "0"' "$out"
expect "the storage Secret is the user's" 'secretName: "offsite"' "$out"
expect "Secret mounted read-only" "readOnly: true" "$out"
expect "runs as non-root" "runAsNonRoot: true" "$out"
expect "read-only root filesystem" "readOnlyRootFilesystem: true" "$out"
expect "no service account token" "automountServiceAccountToken: false" "$out"

# 4. Credentials stay apart: the dump container never sees the storage Secret, the upload container never sees database credentials.
dump="$(awk '/- name: dump/{f=1} /- name: upload/{f=0} f' <<<"$out")"
upload="$(awk '/- name: upload/{f=1} /^          volumes:/{f=0} f' <<<"$out")"
reject "dump container has no rclone mount" "mountPath: /config/rclone" "$dump"
expect "dump container has the database user" "PGUSER" "$dump"
reject "upload container has no database credentials" "PGPASSWORD" "$upload"
reject "upload container has no database user" "DB_USER" "$upload"
expect "upload container has the rclone config" "mountPath: /config/rclone" "$upload"

# 5. Retention, path, schedule and a dedicated database Secret.
out="$(render "${on[@]}" --set backup.retentionDays=14 --set backup.path=prod/openctem --set backup.schedule='5 1 * * 0' \
  --set backup.database.existingSecret=backup-ro -s templates/backup-cronjob.yaml)"
expect "retention override" 'value: "14"' "$out"
expect "path override" 'openctem-crypt:prod/openctem' "$out"
expect "schedule override" 'schedule: "5 1 * * 0"' "$out"
expect "dedicated database Secret" 'name: "backup-ro"' "$out"

# 6. Images are pinned by digest.
out="$(render "${on[@]}" -s templates/backup-cronjob.yaml)"
expect "rclone image pinned" "rclone/rclone:1.75.2@sha256:" "$out"
expect "postgres image pinned" "library/postgres:17-alpine@sha256:" "$out"

# 7. The schema rejects a path that could escape the folder and an unknown key.
out="$(render "${on[@]}" --set backup.path=../etc || true)"
expect "path with .. is refused by the schema" "backup.path" "$out"
out="$(render "${on[@]}" --set backup.bogus=1 || true)"
expect "unknown backup key is refused" "bogus" "$out"

# 8. Bundled database: the pod carries the release labels the NetworkPolicy allows.
out="$(render "${on[@]}" --set networkPolicy.enabled=true -s templates/backup-cronjob.yaml)"
expect "pod has the instance label" "app.kubernetes.io/instance: t" "$out"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all backup checks passed"
