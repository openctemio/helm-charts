# OpenCTEM Helm Charts

This repository hosts official Helm charts for OpenCTEM.

## Usage

Once GitHub Pages is enabled for this repository and the release workflow has published an index, add the chart repository:

```bash
helm repo add openctem https://openctemio.github.io/helm-charts
helm repo update
```

Then install a chart:

```bash
helm install my-openctem openctem/openctem
```

## Repository Layout

- `charts/`: chart source directories
- `.github/workflows/lint-test.yaml`: lint and template validation on PRs
- `.github/workflows/release.yaml`: packages and publishes chart releases

## Releasing a Chart

1. Update the chart version in `charts/<chart-name>/Chart.yaml`.
2. Merge to `main`.
3. GitHub Actions runs the release workflow and updates `index.yaml` for GitHub Pages.

## Contributing

See `CONTRIBUTING.md` for local development and contribution guidelines.
