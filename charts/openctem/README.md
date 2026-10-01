# OpenCTEM Helm chart

Deploys the OpenCTEM API + UI, with an optional bundled sensor and optional
bundled PostgreSQL/Redis for dev/eval. This chart is **secure-by-default**:
`api.appEnv` defaults to `production`, which turns the API's `validateProduction()` into a hard boot gate
(DB TLS, Redis TLS + strong password, ≥64-char JWT secret, encryption key,
secure cookies).

## Quick start (dev / eval)

```bash
helm dependency build charts/openctem
helm install octem charts/openctem \
  --set api.appEnv=development        # relax the production boot gates
```

Dev/eval uses the **bundled** Bitnami Postgres/Redis. Do not use it for real data.

## Production

Use the provided example values, fill every `<PLACEHOLDER>`, and deploy:

```bash
helm upgrade --install openctem charts/openctem \
  -n openctem --create-namespace \
  -f charts/openctem/values-production.yaml
helm test openctem -n openctem      # smoke-check /health and /
```

Production checklist (the chart enforces / warns on most of these):

- **Run ≥ 2 replicas** for the API and UI (`values-production.yaml` sets 2),
  with a PodDisruptionBudget (`minAvailable: 1`) and
  `topologySpreadConstraints` so replicas don't co-locate.
- **External datastores** — set `postgresql.enabled=false` /
  `redis.enabled=false` and point `database.*` / `redisConfig.*` at managed
  Postgres/Redis with TLS (see "Datastores" below).
- **Stable secrets** — see "Secrets & GitOps" below (required in production).
- **NetworkPolicy** — enable `networkPolicy.enabled` on a CNI that enforces it.

## Secrets & GitOps (IMPORTANT — data-loss footgun)

`APP_ENCRYPTION_KEY` encrypts stored integration credentials and
`AUTH_JWT_SECRET` signs sessions. Both must stay **stable forever**: rotating
the encryption key makes all stored integration credentials permanently
undecryptable; rotating the JWT secret logs every user out.

For dev/staging the chart can auto-generate these once and reuse them across
upgrades via a cluster `lookup`. **That pattern is unsafe under GitOps**
(`helm template`, ArgoCD, Flux): `lookup` returns empty on every render, so the
keys would regenerate on every sync.

Therefore, when `api.appEnv=production` the chart is **fail-closed**: it will
refuse to render unless you provide a stable value for each. Provide **one** of:

- `api.encryption.existingSecret` / `api.auth.existingSecret` — **recommended**.
  Works cleanly with External Secrets Operator, sealed-secrets and GitOps.

  ```yaml
  api:
    encryption: { existingSecret: openctem-api-encryption, keyRef: APP_ENCRYPTION_KEY }
    auth:       { existingSecret: openctem-api-jwt,        jwtSecretKey: AUTH_JWT_SECRET }
  ```

- or explicit values `api.encryption.key` / `api.auth.jwtSecret` (kept stable in
  your values source):
  `openssl rand -hex 32` (encryption) and `openssl rand -base64 48` (JWT).

The UI `CSRF_SECRET` is lower stakes (rotating it just re-issues CSRF tokens),
so it is a **warning**, not a hard failure — but for GitOps stability set
`ui.secret.csrfToken` or `ui.secret.existingSecret`.

## Datastores (bundled = dev/eval only)

The bundled Bitnami Postgres/Redis subcharts are single-instance, unbacked-up,
and **Bitnami has deprecated its free Docker Hub images** (a supply-chain risk
for the bundled path). The bundled Redis also cannot terminate TLS, so it can
never satisfy the production Redis boot gate.

**Production must use external managed datastores** with TLS:
`postgresql.enabled=false` + `database.*`, `redis.enabled=false` +
`redisConfig.*` (+ `api.redis.tlsEnabled=true`, `api.migrations.sslMode=require`).

Subchart versions are **pinned** (Postgres 18.5.6, Redis 25.3.2) for
reproducible builds; bump deliberately and re-run `helm dependency update`.

## Rollback & down-migration

`helm rollback` reverts Kubernetes manifests **only** — it does **not**
down-migrate the database. The schema stays at the newer version, so the app
version you roll back to must be forward-compatible with it (OpenCTEM migrations
are designed to be). If it is not, revert the schema first:

```bash
# Gated, manual down-migration Job (disabled by default). Back up the DB first.
helm upgrade openctem charts/openctem -n openctem -f values-production.yaml \
  --set api.migrations.downMigration.enabled=true \
  --set api.migrations.downMigration.steps=1
# runs `migrate ... down 1`; then disable it again.
```

or run `migrate ... down <N>` by hand against the database.

## NetworkPolicy

`networkPolicy.enabled=true` renders a default-deny-ingress baseline plus allow
rules for the real flows (ingress→ui, ui/test→api, api/migrations→postgres:5432
& redis:6379, api egress). Requires a CNI that enforces NetworkPolicy, and a
**dedicated namespace** (the default-deny selects every pod in the namespace).
API egress defaults to permissive (`networkPolicy.api.egress.allowAll=true`) so
threat-intel / CVE / CT feeds keep working; pin it with
`networkPolicy.api.egress.extra` when you can enumerate those endpoints.

## helm test

`helm test <release>` runs an in-cluster Pod that curls the API `/health` and
the UI `/`. Toggle with `tests.enabled`.

## Bundled sensor (optional)

`sensor.enabled=true` runs a co-located OpenCTEM sensor (`openctemio-sensor`)
next to the API, for work the cluster can reach (public DAST, recon,
validation). Scanning an internal network still needs a remote sensor.

```bash
# 1. In the UI: Settings → Sensors → Add sensor; copy its API key.
kubectl -n openctem create secret generic openctem-sensor --from-literal=api-key=<key>
# 2. Enable it.
helm upgrade openctem charts/openctem -n openctem -f values.yaml \
  --set sensor.enabled=true --set sensor.existingSecret=openctem-sensor
```

| Value | Default | Meaning |
|---|---|---|
| `sensor.mode` | `daemon` | `daemon`: API-key sensor (`-daemon -enable-commands`) that runs the scans the platform dispatches. `platform`: the `-platform` bootstrap-token self-registration chart ≤ 0.4.x ran; it needs `/api/v1/platform/{register,lease,poll}`, which the OpenCTEM API does not serve. |
| `sensor.image.repository` / `.tag` | `ghcr.io/openctemio/sensor` / `v0.3.0-default` | The sensor is versioned separately from the platform, so the tag does not follow `appVersion`. Tags are `<version>-<variant>` (no plain `v0.3.0`): `default` (semgrep, betterleaks, trivy, nuclei), `nuclei`, `betterleaks`, `semgrep`, `trivy`, `ci`; `latest-<variant>` also exists. Betterleaks replaced gitleaks after sensor v0.3.0 (whose images carry gitleaks and a semgrep that fails to start); `-gitleaks` tags are no longer published. |
| `sensor.apiKey` / `sensor.existingSecret` / `sensor.existingSecretKey` | — / — / `api-key` | The credential: the API key (daemon) or bootstrap token (platform, key `bootstrap-token`). Prefer `existingSecret`. |
| `sensor.tools` | `nuclei` | Daemon: scanners offered for dispatched jobs (`-tools`), e.g. `nuclei,semgrep,betterleaks,trivy`. `gitleaks` is still accepted and runs betterleaks. |
| `sensor.allowPrivateTargets` | empty | `"1"` sets `SENSOR_ALLOW_PRIVATE_TARGETS=1` (RFC1918 / ULA targets allowed). Empty keeps them blocked. Any other value fails the render: the sensor only recognises `1`. Reaching the in-cluster API needs nothing (the sensor's API client allows the platform's private address). |
| `sensor.scanRoots` | empty | `SENSOR_SCAN_ROOTS` for dispatched code scans; empty = `/scan`. |
| `sensor.keyAutoRenew` | `false` | `PLATFORM_KEY_AUTORENEW`. The renewed key is kept in the pod filesystem, not the Secret, so in daemon mode a restart after a renewal comes back with the revoked key. |
| `sensor.maxConcurrent`, `sensor.executors.*` | `5`, vulnscan | Platform mode only. |

## Upgrading to 0.5.0 (OpenCTEM v0.9.0: agents are now sensors)

Chart 0.5.0 sets `appVersion: v0.9.0` and completes the agent → sensor rename
(RFC-023 §9.5). Read the platform's
[upgrade guide](https://github.com/openctemio/docs/blob/main/operations/upgrade-to-v0.9.md)
first: migration `000230` renames tables and columns, so **scale the API (and
UI) to zero before `helm upgrade`** — the migration Job is a `pre-upgrade`
hook and old API pods fail on the renamed schema while it runs.

**Values.** An old values file with `agent:` keeps working; nothing has to
change for the upgrade itself:

| Old (chart ≤ 0.4.x) | New | Automatic mapping |
|---|---|---|
| `agent.<key>` | `sensor.<key>` | Every key, same name. `helm upgrade` prints a deprecation notice listing them. |
| `agent.image.repository: ghcr.io/openctemio/agent` (+ `tag`) | `sensor.image` (`ghcr.io/openctemio/sensor:v0.3.0-default`) | The frozen agent image and its tag are ignored (its `v0.2.x` tags do not exist on the sensor repository). A custom repository (mirror) is kept with its tag. |
| `agent.allowPrivateTargets: true` / `false` | `sensor.allowPrivateTargets: "1"` / `""` | Note: chart ≤ 0.4.x rendered `"true"`, which the binary ignores, so `true` never took effect. It now does; the notice says so. |
| (always `-platform` + bootstrap token) | `sensor.mode: platform` | Selected for an `agent:` block unless `sensor.mode` or `sensor.apiKey` is set. Switch to `daemon` (see above): the API does not serve platform registration. |
| `agent.existingSecret` / `existingSecretKey` | `sensor.existingSecret` / `existingSecretKey` | Used unchanged. |
| `api.extraEnv` `AGENT_*` (`AGENT_KEY_TTL`, `AGENT_PUBLIC_API_URL`, `AGENT_CONFIG_TEMPLATES_DIR`, `AGENT_LB_*`) | `SENSOR_*` | Passed to the API under the new name. |

The render **fails**, naming the keys (never the values), only when `agent:`
and `sensor:` set the same key to different values, or `api.extraEnv` sets an
`AGENT_*` and its `SENSOR_*` name to different values — the same rule the
sensor and the API apply to their environment variables. A `sensor.*` value
equal to the chart default counts as unset.

**What happens to the old objects.** The `<fullname>-agent` Deployment and its
`<fullname>-agent-bootstrap` Secret are no longer part of the release, so
`helm upgrade` deletes them and creates `<fullname>-sensor` (component label
`sensor`) and `<fullname>-sensor-credentials`. A Secret you referenced with
`existingSecret` is not owned by the release and is used as is. The new pod
starts from scratch: the old pod kept its sensor credentials only in its
container filesystem.
