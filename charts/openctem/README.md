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

## Single-port gateway (one HTTPS entry point)

Chart 0.7.0 can serve the UI **and** the REST API on one hostname and one HTTPS
port (as Tenable.sc does), so sensors, API clients, SCIM, webhooks and browsers
all use `https://<host>`. It is opt-in: `gateway.mode: none` (the default)
renders exactly what 0.6.0 did, and the per-component `api.ingress` /
`ui.ingress` / `*.httpRoute` keep working (give them a different host).

| `gateway.mode` | Renders | TLS | Routes API-key clients on any `/api/*` |
|---|---|---|---|
| `ingress` | one `Ingress` | ingress (`gateway.ingress.tls`, cert-manager) | **no**: dedicated paths only |
| `httpRoute` | one Gateway API `HTTPRoute` | the parent Gateway's listener | `Bearer oct_*` and `X-API-Key` (header matches) |
| `caddy` | Caddy `Deployment` + `Service` + `ConfigMap` + `PVC` | `internal` / `acme` / `files` / `http` | all rules |

**Routing** (the same in every mode; `caddy` uses the docker-compose
gateway's Caddyfile, copied verbatim into `files/gateway/`, and
`tests/gateway/run.sh` fails if the chart's path list drifts from it):

- to the API: `/api/v1/agent/`, `/api/v2/sensor/`, `/api/v1/platform/`
  (sensors), `/scim/v2/`, `/api/v1/mcp`, `/api/v1/webhooks/incoming/`,
  `/api/v1/auth/saml/`, and exactly `/api/v1/auth/backchannel-logout`,
  `/api/v1/ws`, `/health`, `/openapi.yaml`, `/docs`;
- to the API as well: `/api/*` with `Authorization: Bearer oct_*` or an
  `X-API-Key` header (`httpRoute`, `caddy`), and `/api/*` with
  `Authorization: Bearer *` but no `auth_token` session cookie (`caddy` only:
  Gateway API has no "header absent" match);
- never to the API: `/metrics`, `/ready`, `/debug/*` (`caddy` answers 404; the
  other modes send them to the UI, which has no such pages), and the API's
  ports 9090 / 2345 are never exposed;
- everything else to the UI, including the browser's cookie calls to `/api/v1/*`.

Why the header rules: the UI's `/api/v1` proxy authenticates with the browser's
session cookie and drops the caller's `Authorization` header, so an API-key
client sent there gets 401. **A plain Ingress cannot match headers**, so with
`gateway.mode=ingress` API-key clients work only on the dedicated paths. If
they need every `/api/v1/*` path, use `httpRoute` (needs RegularExpression
header matching, Extended support in Envoy Gateway, Istio, Cilium, NGINX
Gateway Fabric, Traefik, ...) or `caddy`, which can also sit behind your
existing ingress/load balancer with `gateway.caddy.tls.mode=http`.

Any mode also sets, on the API, `SERVER_TRUSTED_PROXIES` (from
`gateway.trustedProxies`), and `APP_URL`, `CORS_ALLOWED_ORIGINS`,
`SMTP_BASE_URL` (from `gateway.publicUrl`, default `https://<host>`; the API
checks the WebSocket `Origin` against `CORS_ALLOWED_ORIGINS`), and on the UI
`TRUST_PROXY_HEADERS=true`. A name already in `api.extraEnv` / `ui.extraEnv`
wins.

| Value | Default | Meaning |
|---|---|---|
| `gateway.mode` | `none` | `none`, `ingress`, `httpRoute`, `caddy`. |
| `gateway.host` | — | Public DNS name (or IP for caddy `internal`/`files`). Required, except caddy `http` with `publicUrl`. |
| `gateway.publicUrl` | `https://<host>` | Public origin; set it for a non-443 port. |
| `gateway.trustedProxies` | — | **Required** with a mode. CIDRs of the pods that connect to the API (gateway/ingress controller and UI), i.e. the cluster's pod CIDR (`10.244.0.0/16` kubeadm/flannel, `10.42.0.0/16` k3s; `kubectl cluster-info dump \| grep -m1 -- --cluster-cidr`). Only these may assert the client IP for the audit log and IP allowlists. Set without a mode, it only sets `SERVER_TRUSTED_PROXIES`. |
| `gateway.ingress.className` / `.annotations` | — | WebSockets and uploads usually need e.g. `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"`, `proxy-body-size: "256m"`. |
| `gateway.ingress.tls.enabled` / `.secretName` | `true` / `<fullname>-gateway-tls` | TLS for `host`. |
| `gateway.ingress.tls.clusterIssuer` / `.issuer` | — | Adds the cert-manager annotation. |
| `gateway.httpRoute.parentRefs` | `[{name: gateway, sectionName: https}]` | The Gateway (and its HTTPS listener). |
| `gateway.httpRoute.apiKeyHeaderRouting` | `true` | The `Bearer oct_*` / `X-API-Key` header rule. |
| `gateway.caddy.image` | `caddy:2.11.4-alpine` | Official image, pinned. |
| `gateway.caddy.tls.mode` | `internal` | `internal`: Caddy's own CA (LAN / IP installs). `acme`: Let's Encrypt (`tls.acme.email` required, `tls.acme.ca`). `files`: your `kubernetes.io/tls` Secret (`tls.files.secretName`, `certKey`, `keyKey`). `http`: plain HTTP on port 80 behind a TLS proxy; **refused unless `tls.allowPlainHttp: true`**. |
| `gateway.caddy.frontProxies` | `[]` | Proxies in front of Caddy whose `X-Forwarded-For` it believes (`http` mode behind an L7 proxy). |
| `gateway.caddy.service.type` | `LoadBalancer` | Exposes **443 only** (`http` mode: 80 only). `service.http.enabled` adds 80 in `acme` mode (HTTP-01 + redirect). `externalTrafficPolicy: Local` keeps the client address. |
| `gateway.caddy.persistence` | PVC `1Gi`, RWO | `/data`: certificates, ACME account, internal CA. Kept on uninstall (`helm.sh/resource-policy: keep`). `enabled: false` = `emptyDir` (a new CA on every reschedule). |
| `gateway.caddy.maxBodySize` | `256MB` | Above the API's largest per-route limit. |

The bundled Caddy runs one replica (its `/data` is ReadWriteOnce) as uid 1000
with a read-only root filesystem, every capability dropped except
`NET_BIND_SERVICE` (the image's `caddy` binary carries that file capability
and will not start without it), and `allowPrivilegeEscalation: false`; this
meets the `restricted` Pod Security Standard. Its admin API (`:2019`) stays
inside the pod.

**Internal CA** (`tls.mode=internal`): give sensors (`SSL_CERT_FILE`) and
browsers the root certificate, created on first start:

```bash
kubectl -n openctem exec deploy/<release>-openctem-gateway -- \
  cat /data/caddy/pki/authorities/local/root.crt > openctem-root-ca.crt
```

Example, bundled Caddy with your own certificate:

```bash
kubectl -n openctem create secret tls openctem-tls --cert=fullchain.pem --key=privkey.pem
helm upgrade --install openctem charts/openctem -n openctem -f values.yaml \
  --set gateway.mode=caddy --set gateway.host=ctem.example.com \
  --set 'gateway.trustedProxies={10.244.0.0/16}' \
  --set gateway.caddy.tls.mode=files --set gateway.caddy.tls.files.secretName=openctem-tls
```

With `networkPolicy.enabled`, the gateway's public port is open to any source;
in `caddy` mode the UI accepts only the gateway (unless `ui.ingress` /
`ui.httpRoute` is also enabled), and in `ingress` / `httpRoute` mode the
ingress controller (`networkPolicy.ingressController*Selector`) may reach the
API on 8080.

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
rules for the real flows (ingress→ui, ui/test→api, the single-port gateway's
flows, api/migrations→postgres:5432
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
| `sensor.outbox.persistence.enabled` | `false` | The sensor (v0.4.0+) keeps results in its outbox at `/var/lib/openctem/outbox` until the platform accepted them. Default: an `emptyDir`, which survives a container restart but **not** a pod deletion, reschedule or upgrade (results still queued then are lost; `helm install` prints a warning). `true` creates a PersistentVolumeClaim `<release>-openctem-sensor-outbox` (`size` `2Gi`, `storageClass`, `accessModes` `[ReadWriteOnce]`) or uses `existingClaim`; it requires `replicaCount: 1` (one sensor per outbox), sets the Deployment strategy to `Recreate`, and gives the pod `fsGroup: 999` (the image user) unless `podSecurityContext` sets one. |
| `sensor.outbox.maxBytes` / `.maxAge` / `.emptyDirSizeLimit` | empty | `SENSOR_OUTBOX_MAX_BYTES` (default `1GiB`, at most half the free space; keep it below the volume), `SENSOR_OUTBOX_MAX_AGE` (default `168h`), and the `emptyDir` size limit. |

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
