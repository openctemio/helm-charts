# Contributing

Thanks for contributing to OpenCTEM Helm charts.

## Requirements

- Helm 4.x
- GitHub Actions permissions enabled for this repository

## Local Validation

Run the following before opening a PR:

```bash
helm lint charts/openctem
helm template charts/openctem
```

## Chart Changes

- Bump `version` in `Chart.yaml` for any chart change.
- Keep `appVersion` in sync with OpenCTEM app release when applicable.
- Document new values in chart README files when added.
