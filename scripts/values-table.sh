#!/usr/bin/env bash
# Regenerates the values table in charts/openctem/README.md (between the
# values-table markers) from the `# --` comments in values.yaml, with
# helm-docs (https://github.com/norwoodj/helm-docs).
#   scripts/values-table.sh          rewrite the table
#   scripts/values-table.sh --check  fail when the table is stale (CI)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/openctem"
readme="$chart/README.md"
command -v helm-docs >/dev/null || { echo "helm-docs not found (https://github.com/norwoodj/helm-docs)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo '{{ template "chart.valuesTable" . }}' > "$tmp/table.gotmpl"
helm-docs --chart-search-root "$chart" --template-files "$tmp/table.gotmpl" --output-file "$tmp/table.md" --dry-run > "$tmp/raw.md" 2>/dev/null

python3 - "$tmp/raw.md" "$readme" "$tmp/new.md" <<'PY'
import re, sys
raw, readme, out = sys.argv[1:]
rows = []
for line in open(raw):
    m = re.match(r"^\| (\S+) \| (\S+) \| (.*) \|$", line.rstrip("\n"))
    if not m or m.group(1) in ("Key", "-----"):
        continue
    key, typ, rest = m.groups()
    # helm-docs leaves "|" in descriptions and defaults unescaped; the default
    # is the first backtick-quoted field.
    d = re.match(r"^(`.*?`) \| (.*)$", rest)
    default, desc = d.groups() if d else (rest, "")
    if len(default) > 90:
        default = "see `values.yaml`"
    desc = re.sub(r"\s{2,}", " ", desc).strip()
    desc = re.sub(r"(?<!\\)\|", r"\\|", desc)
    rows.append(f"| `{key}` | {typ} | {default} | {desc} |")
table = "| Key | Type | Default | Description |\n|-----|------|---------|-------------|\n" + "\n".join(rows) + "\n"
s = open(readme).read()
start, end = "<!-- values-table:start -->\n", "<!-- values-table:end -->"
i, j = s.index(start) + len(start), s.index(end)
open(out, "w").write(s[:i] + table + s[j:])
PY

if [ "${1:-}" = --check ]; then
  if ! diff -u "$readme" "$tmp/new.md"; then
    echo "::error::charts/openctem/README.md values table is stale: run scripts/values-table.sh" >&2
    exit 1
  fi
  echo "values table is current"
else
  cp "$tmp/new.md" "$readme"
fi
