# OpenCTEM Helm chart

Deploys the OpenCTEM API + UI, with optional bundled PostgreSQL/Redis for
dev/eval. This chart is **secure-by-default**: `api.appEnv` defaults to
`production`, which turns the API's `validateProduction()` into a hard boot gate
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
