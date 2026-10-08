# Contributing

Thanks for contributing to the OpenCTEM Helm charts.

## Requirements

- Helm 4.x (CI uses v4.1.3)
- [helm-docs](https://github.com/norwoodj/helm-docs) to refresh the values table

## Local validation

Run the following before opening a PR:

```bash
helm dependency build charts/openctem
helm lint charts/openctem --set api.appEnv=development
helm lint charts/openctem -f charts/openctem/values-production.yaml
helm template charts/openctem --set api.appEnv=development
```

and the render tests CI runs, for example `tests/sensor-hardening/run.sh` and
`tests/gateway/run.sh` (see `.github/workflows/lint-test.yaml` for the full
list).

## Chart changes

- Bump `version` in `Chart.yaml` for any chart change.
- Keep `appVersion` in sync with the OpenCTEM release when applicable.
- Document each new value with a `# --` comment in `values.yaml`, then refresh
  the [values table](charts/openctem/README.md#values) in the chart README
  (between the `values-table` markers) from helm-docs' `chart.valuesTable`
  template. Escape `|` in descriptions and replace very long object defaults
  with "see `values.yaml`".
- Never edit the copies under `charts/openctem/files/gateway/` and
  `charts/openctem/files/monitoring/` by hand: run `scripts/sync-gateway.sh`
  or `scripts/sync-monitoring.sh`.

## Security

Do not open public issues for vulnerabilities; see [SECURITY.md](SECURITY.md).
