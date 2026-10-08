# OpenCTEM Helm Charts

Official Helm charts for [OpenCTEM](https://openctem.io), the open-source
Continuous Threat Exposure Management (CTEM) platform. Product documentation:
[docs.openctem.io](https://docs.openctem.io).

| Chart | Description |
|---|---|
| [`openctem`](charts/openctem/README.md) | The OpenCTEM API and web console, with an optional bundled sensor and optional bundled PostgreSQL/Redis for dev/eval |

## Usage

Add the chart repository (published to GitHub Pages by the release workflow):

```bash
helm repo add openctem https://openctemio.github.io/helm-charts
helm repo update
helm search repo openctem
```

Then install the chart:

```bash
helm install openctem openctem/openctem -n openctem --create-namespace
```

Read the [chart README](charts/openctem/README.md) first: the chart is
secure by default (`api.appEnv: production` refuses to boot without TLS
datastores and stable secrets), and its
[Versions](charts/openctem/README.md#versions) section says which OpenCTEM
release each chart version installs.

The chart installs no login by default. For the first platform administrator
(plus a break-glass backup) and the first organization, enable
`api.bootstrapAdmin` with `api.bootstrapAdmin.org.*`; organizations are
created by the platform administrator only (`api.tenantCreationMode:
admin_only`, the default). See
[First install](charts/openctem/README.md#first-install-platform-admin-and-first-organization)
for the walkthrough.

## Repository layout

- `charts/`: chart source directories
- `scripts/`: copy the gateway and monitoring files from the OpenCTEM repository (`sync-gateway.sh`, `sync-monitoring.sh`)
- `tests/`: render tests run in CI
- `.github/workflows/lint-test.yaml`: lint and template validation on pull requests
- `.github/workflows/release.yaml`: packages and publishes chart releases

## Releasing a chart

1. Update the chart version in `charts/<chart-name>/Chart.yaml`.
2. Merge to `main`.
3. The release workflow (chart-releaser) publishes the chart as a GitHub
   release and updates `index.yaml` on GitHub Pages.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

Apache License 2.0; see [LICENSE](LICENSE).
