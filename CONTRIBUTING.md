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

and the render tests CI runs, for example `tests/production/run.sh`,
`tests/sensor-hardening/run.sh` and
`tests/gateway/run.sh` (see `.github/workflows/lint-test.yaml` for the full
list). `tests/kubeconform/run.sh` validates the renders against the Kubernetes
schemas ([kubeconform](https://github.com/yannh/kubeconform)), and
`tests/kind/run.sh` installs the chart on a [kind](https://kind.sigs.k8s.io)
cluster (`kind create cluster --name chart-smoke` first).

## Chart changes

- Bump `version` in `Chart.yaml` for any chart change.
- Keep `appVersion` in sync with the OpenCTEM release when applicable.
- Document each new value with a `# --` comment in `values.yaml` (and its type
  in `charts/openctem/values.schema.json`), then refresh the
  [values table](charts/openctem/README.md#values) with
  `scripts/values-table.sh` (helm-docs; CI runs it with `--check`).
- Never edit the copies under `charts/openctem/files/gateway/` and
  `charts/openctem/files/monitoring/` by hand: run `scripts/sync-gateway.sh`
  or `scripts/sync-monitoring.sh`.

## Security

Do not open public issues for vulnerabilities; see [SECURITY.md](SECURITY.md).

## Contributor License Agreement

Every outside contribution is accepted under the OpenCTEM Contributor License
Agreement (CLA). It keeps your copyright with you and grants the project a
license that lets it offer OpenCTEM under its open source license and under
other terms (for example a commercial license). A summary is in
[CLA.md](CLA.md); the full texts are the
[Individual CLA](https://docs.openctem.io/legal/cla/) and the
[Corporate CLA](https://docs.openctem.io/legal/cla-corporate/).

### How to sign

1. Make sure the e-mail address of your commits is
   [added to your GitHub account](https://github.com/settings/emails). The
   check can only match commits that are linked to a GitHub account.
2. Open your pull request. If a commit author has not accepted the CLA yet,
   the `cla` check fails and comments on the pull request.
3. Read the agreement and post this comment on the pull request:

   ```text
   I have read the CLA Document and I hereby sign the CLA
   ```

   The check re-runs and passes. You sign once; the signature covers every
   repository of the `openctemio` organization and your earlier
   contributions. Post `recheck` to run the check again.
4. If you contribute as part of your job and your employer has rights in your
   work, your employer signs the [Corporate CLA](CLA-CORPORATE.md) as well.

The maintainer and the dependency bots are on the check's allowlist. A
maintainer who opens a pull request with someone else's commits makes sure
those authors have signed; the check also runs then for every commit linked
to another GitHub account.

### What is recorded

Your acceptance is recorded in a private repository that only the maintainer
can read: your GitHub username and numeric account id, the id and time of
your signing comment, and the repository and pull request where you signed.
No e-mail address is stored. The signing comment itself stays public on the
pull request. The record is kept for as long as the project distributes your
contribution, because it is the evidence of the license. To see or correct
your record, or to ask for its removal, write to info@openctem.io; anything
not needed as evidence of the license is removed.
