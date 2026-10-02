# OpenCTEM Helm chart

Deploys the OpenCTEM API + UI, with an optional bundled sensor and optional
bundled PostgreSQL/Redis for dev/eval. This chart is **secure-by-default**:
`api.appEnv` defaults to `production`, which turns the API's `validateProduction()` into a hard boot gate
(DB TLS, Redis TLS + strong password, ≥64-char JWT secret, encryption key,
secure cookies).

## Versions

`appVersion` is the default tag of the API, web console and migrations images,
and must be a released [OpenCTEM](https://github.com/openctemio/openctem/releases)
tag. The release workflow of `openctemio/openctem` opens the chart PR that
bumps it after each release (OpenCTEM RFC-037). CI warns when it names a tag
that does not exist (`tests/versions/check-published.sh`).

| Chart | appVersion (OpenCTEM) | Default images |
|---|---|---|
| 0.4.1 | v0.8.0 | `openctemio/api`, `openctemio/ui`, `openctemio/migrations` (Docker Hub, never published) |
| 0.5.0 – 0.10.x | v0.9.0 | `ghcr.io/openctemio/openctem-api`, `ghcr.io/openctemio/openctem-web`, `ghcr.io/openctemio/migrations` |

> **OpenCTEM v0.9.0 is not released yet**, so no published chart installs
> with its default image values today. Charts 0.5.0 to 0.10.x were published
> ahead of v0.9.0 and pull `openctem-api:v0.9.0`, which does not exist yet.
> Chart 0.4.1 (v0.8.0) names Docker Hub repositories that were never
> published. Until v0.9.0 is tagged, deploy v0.8.0 with chart 0.4.1 and the
> GHCR images:
>
> ```bash
> helm install openctem openctem/openctem --version 0.4.1 \
>   --set api.image.repository=ghcr.io/openctemio/api \
>   --set ui.image.repository=ghcr.io/openctemio/ui \
>   --set api.migrations.image.repository=ghcr.io/openctemio/migrations
> ```
>
> Do not point chart 0.5.0+ at v0.8.0 images: those charts rename the agent
> to the sensor, which needs the v0.9.0 API.

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

## First install: platform admin and first organization

OpenCTEM has no self-registration and, by default, no self-service
organizations: the **platform administrator** creates organizations, as in
Tenable Security Center. The administrator is not a member of any
organization (it cannot see organization data); each organization has its own
owner, who invites users or configures SSO.

Bootstrap the administrators and the first organization in the install itself:

```yaml
api:
  tenantCreationMode: admin_only        # the default
  bootstrapAdmin:
    enabled: true
    email: admin@acme.io                # platform administrator
    backupEmail: breakglass@acme.io     # break-glass backup administrator
    org:
      name: "Acme Security"             # first organization
      ownerEmail: owner@acme.io         # its owner (not one of the admins)
```

1. `helm install`. After the migrations, a post-install Job runs
   `/app/bootstrap-admin`. It creates both administrators, each with a
   temporary password printed **once** to the Job log, and creates the
   organization through the normal, audited organization service. The owner
   gets a one-time set-password link (valid 24h): emailed when SMTP is
   configured (`SMTP_*` in `api.extraEnv` / `api.extraEnvFrom`; the link base
   is `SMTP_BASE_URL`, which `gateway.*` sets), otherwise printed in the Job
   log.
2. Read the log once and store the credentials (the break-glass ones offline):

   ```bash
   kubectl logs -n <ns> job/<fullname>-api-bootstrap-admin
   kubectl delete -n <ns> job/<fullname>-api-bootstrap-admin
   ```

   `<fullname>` is `<release>-openctem` (or just `<release>` when the release
   name contains `openctem`); `helm install` prints the exact commands. The
   Job is **kept** until you delete it (it is not deleted on success and has
   no `ttlSecondsAfterFinished`), so the one-time credentials cannot vanish
   before you read them.
3. The administrators sign in on `/login`, open the admin console (`/admin`),
   enroll an authenticator (TOTP) and change the temporary password.
4. The owner sets a password with the link, signs in on `/login`, then invites
   users or configures SSO for the organization.

Further organizations: admin console → Organizations → Create. The Job fails
the release on a real error. Re-running the CLI is safe (existing admins are
left unchanged, an existing organization slug is skipped), e.g. to add the
first organization to an install that skipped it:

```bash
kubectl exec -n <ns> deploy/<fullname>-api -- /app/bootstrap-admin \
  -email=admin@acme.io -backup-email=breakglass@acme.io \
  -org-name="Acme Security" -org-owner-email=owner@acme.io
```

**Why the pod log and not a Secret.** Writing the credentials to a Kubernetes
Secret would need the Job's ServiceAccount (shared with the API pods) to get
create/patch on Secrets, a namespace-wide write privilege, plus a Kubernetes
client in the API image. The pod log is already protected by `pods/log` RBAC,
the passwords are temporary (they must be changed at first sign-in) and the
owner link expires in 24h.

| Value | Default | |
|---|---|---|
| `api.tenantCreationMode` | `admin_only` | `TENANT_CREATION_MODE`. `admin_only`: only the platform administrator creates organizations (admin console or the bootstrap-admin org flags). `self_service`: any signed-in user may create organizations (SaaS / trial opt-in). Any other value fails the render. A `TENANT_CREATION_MODE` in `api.extraEnv` wins. |
| `api.sensorReleaseChannel.latestVersion` | `""` | `SENSOR_LATEST_VERSION`: the newest sensor release. The Sensors page shows "update available" for older sensors and its install commands pin this tag. Empty: `sensor.image.tag`. An entry in `api.extraEnv` wins (`none` turns the comparison off). |
| `api.sensorReleaseChannel.minVersion` | `""` | `SENSOR_MIN_VERSION`: the oldest supported sensor release. A heartbeating sensor below it shows as degraded. Empty: no minimum. |
| `api.bootstrapAdmin.enabled` | `false` | Run the post-install bootstrap Job. |
| `api.bootstrapAdmin.email` / `name` / `role` | — / — / `super_admin` | The platform administrator. |
| `api.bootstrapAdmin.backupEmail` / `backupName` | — | The break-glass backup administrator (required unless `noBackup: true`). |
| `api.bootstrapAdmin.noBackup` / `force` | `false` | `-no-backup` (not recommended) / `-force` (delete and re-create an existing admin). |
| `api.bootstrapAdmin.org.name` / `ownerEmail` | — | The first organization and its owner. Set both or neither (the render fails otherwise). |
| `api.bootstrapAdmin.org.slug` / `ownerName` | — | Optional. Empty: derived from the name / the email. |
| `api.bootstrapAdmin.backoffLimit` / `activeDeadlineSeconds` | `0` / `300` | Job retries (0: a failure is reported once) and deadline. |

The Job also gets the API's `api.extraEnv`, `api.extraEnvFrom` and gateway
environment, so it sends the owner's email with the same SMTP settings as the
API. It runs the binary without a shell, so values with spaces or quotes are
passed verbatim.

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

## Attachment storage

Uploaded attachments and finding evidence (`api.attachments`) live either on a
volume or in an S3-compatible bucket. Before chart 0.10.0 they were written to
the API pod's own filesystem: lost on every restart or upgrade, and split
across pods when more than one API replica ran.

| Setup | Values | Replicas |
|---|---|---|
| Volume, ReadWriteOnce (default) | `api.attachments.storage=local` (10Gi PVC at `/app/data`) | 1 (the Deployment uses `Recreate`) |
| Volume, ReadWriteMany | `api.attachments.persistence.accessModes={ReadWriteMany}` + an RWX `storageClass` (NFS, CephFS, EFS, Azure Files, ...) | any |
| S3 / MinIO | `api.attachments.storage=s3`, `s3.bucket`, `s3.existingSecret` (keys `STORAGE_ACCESS_KEY` / `STORAGE_SECRET_KEY`), `s3.endpoint` for MinIO | any |
| No persistence | `api.attachments.persistence.enabled=false` (emptyDir) | 1, files lost with the pod |

Rendering **fails** when the API can run more than one pod (`api.replicaCount > 1`,
or `api.autoscaling.enabled` with `maxReplicas > 1`) and the storage is a
ReadWriteOnce volume or an emptyDir: only one pod could mount it, or each pod
would see different files. With `existingClaim`, list `ReadWriteMany` in
`accessModes` to confirm the claim is RWX.

```bash
kubectl -n openctem create secret generic openctem-attachments-s3 \
  --from-literal=STORAGE_ACCESS_KEY=... --from-literal=STORAGE_SECRET_KEY=...
helm upgrade --install openctem openctemio/openctem -n openctem \
  --set api.attachments.storage=s3 \
  --set api.attachments.s3.bucket=openctem-attachments \
  --set api.attachments.s3.existingSecret=openctem-attachments-s3
# MinIO: --set api.attachments.s3.provider=minio --set api.attachments.s3.endpoint=http://minio.storage.svc:9000
```

S3 storage needs an API release with server-wide S3 support
(`STORAGE_PROVIDER=s3`, openctemio/openctem#781); older API images ignore it
and keep files on the pod's disk. The created PVC carries
`helm.sh/resource-policy: keep`, so `helm uninstall` leaves the files; delete
the claim by hand to remove them. Switching storage later does not move
existing files. Back the volume or bucket up together with the database.

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
| `sensor.mode` | `daemon` | The only mode: an API-key sensor (`-daemon -enable-commands`) that runs the scans the platform dispatches. `platform` (bootstrap-token self-registration) was removed in 0.9.0 and fails the render: no OpenCTEM API serves it. |
| `sensor.image.repository` / `.tag` | `ghcr.io/openctemio/sensor` / `v0.6.3` | The sensor is versioned separately from the platform, so the tag does not follow `appVersion`. From v0.4.2 the plain tag (`v0.4.2`, `latest`) is the default image (semgrep, betterleaks, trivy, nuclei), the same as `v0.4.2-default`. Other variants: `<version>-nuclei`, `-betterleaks`, `-semgrep`, `-trivy`, `-ci`. v0.4.x adds the durable results outbox; v0.5.0 speaks protocol v2 for the whole sensor surface; v0.6.3 runs on the SDK's sensor runtime (sdk-go v0.12.0), detects its own tools and keeps a renewed API key in its state volume (RFC-032 Phase 0). Betterleaks replaced gitleaks after sensor v0.3.0 (whose images carry gitleaks and a semgrep that fails to start); `-gitleaks` tags are no longer published. |
| `sensor.apiKey` / `sensor.existingSecret` / `sensor.existingSecretKey` | — / — / `api-key` | The sensor's API key. Prefer `existingSecret`. |
| `sensor.tools` | `nuclei` | Daemon: scanners offered for dispatched jobs (`-tools`), e.g. `nuclei,semgrep,betterleaks,trivy`. `gitleaks` is still accepted and runs betterleaks. |
| `sensor.allowPrivateTargets` | empty | `"1"` sets `SENSOR_ALLOW_PRIVATE_TARGETS=1` (RFC1918 / ULA targets allowed). Empty keeps them blocked. Any other value fails the render: the sensor only recognises `1`. Reaching the in-cluster API needs nothing (the sensor's API client allows the platform's private address). |
| `sensor.scanRoots` | empty | `SENSOR_SCAN_ROOTS` for dispatched code scans; empty = `/scan`. |
| `sensor.keyAutoRenew` | empty | `PLATFORM_KEY_AUTORENEW`, always rendered. Empty: on exactly when `sensor.state.persistence.enabled`; `true` / `false` force it. The renewed key is kept in the state volume (`-credentials=/var/lib/openctem/state/sensor-credentials.json`), not the Secret: the renewal retires the key in the Secret, so a pod without that volume would start with a dead key. The API issues expiring keys only with `SENSOR_KEY_TTL`. |
| `sensor.state.persistence.enabled` | `true` | The sensor's state at `/var/lib/openctem/state` (`SENSOR_STATE_DIR`): the API key it renews on its own. A PersistentVolumeClaim `<release>-openctem-sensor-state` (`size` `128Mi`, `storageClass`, `accessModes`) or `existingClaim`. It holds a credential: back it up like one. `false`: an `emptyDir`, and key auto-renewal stays off. |
| `sensor.content.persistence.enabled` | `true` | Scanner content cache at `/var/lib/openctem/content` (`SENSOR_CONTENT_DIR`: trivy DB, nuclei templates, semgrep rules), so a new pod does not download it again. A PersistentVolumeClaim `<release>-openctem-sensor-content` (`size` `5Gi`) or `existingClaim`. Disposable, and kept apart from the state. `false`: an `emptyDir` (`sensor.content.emptyDirSizeLimit`). |
| `sensor.outbox.persistence.enabled` | `false` | The sensor (v0.4.0+) keeps results in its outbox at `/var/lib/openctem/outbox` until the platform accepted them. Default: an `emptyDir`, which survives a container restart but **not** a pod deletion, reschedule or upgrade (results still queued then are lost; `helm install` prints a warning). `true` creates a PersistentVolumeClaim `<release>-openctem-sensor-outbox` (`size` `2Gi`, `storageClass`, `accessModes` `[ReadWriteOnce]`) or uses `existingClaim`; it requires `replicaCount: 1` (one sensor per outbox), sets the Deployment strategy to `Recreate`, and gives the pod `fsGroup: 999` (the image user) unless `podSecurityContext` sets one. Any sensor PVC (outbox, state, content) requires `replicaCount: 1`, sets `Recreate` and the `fsGroup`. |
| `sensor.outbox.maxBytes` / `.maxAge` / `.emptyDirSizeLimit` | empty | `SENSOR_OUTBOX_MAX_BYTES` (default `1GiB`, at most half the free space; keep it below the volume), `SENSOR_OUTBOX_MAX_AGE` (default `168h`), and the `emptyDir` size limit. |

## Upgrading to 0.10.0 (attachments on a volume or S3)

The API now keeps attachments on a 10Gi ReadWriteOnce PVC at `/app/data` by
default (see [Attachment storage](#attachment-storage)); the cluster needs a
default StorageClass, or set `api.attachments.persistence.storageClass`. With a
ReadWriteOnce volume the API Deployment switches to the `Recreate` strategy
(a short gap during upgrades) unless `api.deploymentStrategy` is set.

**Several API replicas** (`api.replicaCount > 1` or autoscaling, as in
`values-production.yaml`) no longer render on that default: choose
`api.attachments.storage=s3` or a ReadWriteMany volume. Files written to the
pod's filesystem by earlier chart versions are not migrated (they were lost on
every pod restart anyway).

## Upgrading to 0.9.3 (image names from the openctem monorepo)

The API and the web console now ship from one repository,
[openctemio/openctem](https://github.com/openctemio/openctem) (`api/` and
`web/`), and one `vX.Y.Z` tag publishes both. The default images follow the new
names:

| Value | Old default | New default |
|---|---|---|
| `api.image.repository` | `ghcr.io/openctemio/api` | `ghcr.io/openctemio/openctem-api` |
| `ui.image.repository` | `ghcr.io/openctemio/ui` | `ghcr.io/openctemio/openctem-web` |

`values-production.yaml` named the bare Docker Hub repositories `openctemio/api`
and `openctemio/ui`, which were never published; it now uses the GHCR names
too. The new names are published from OpenCTEM v0.9.0. The old GHCR names keep
receiving identical copies for a transition window, and they are the ones to
use when you pin `api.image.tag` / `ui.image.tag` to v0.8.0 or older.
`api.migrations.image` (`ghcr.io/openctemio/migrations`) is unchanged.

## Upgrading to 0.9.0 (sensor state and content volumes, platform mode removed)

- **The bundled sensor gets two PersistentVolumeClaims by default**:
  `<release>-openctem-sensor-state` (128Mi, the API key the sensor renews on
  its own) and `<release>-openctem-sensor-content` (5Gi, the scanner content
  cache), and the Deployment switches to `Recreate`. The cluster needs a
  default StorageClass (or set `storageClass` / `existingClaim`). To keep
  emptyDirs, set `sensor.state.persistence.enabled=false` and
  `sensor.content.persistence.enabled=false`. With more than one replica
  both must be off (a sensor is one identity; replicas sharing a key are
  flagged as a cloned identity by the platform).
- **Key auto-renewal is on by default** (with the state volume):
  `PLATFORM_KEY_AUTORENEW=true` and `-credentials` in the state volume. The
  first renewal retires the key in the Secret; the pod keeps the renewed key
  in the volume. If you regenerate the key under Settings → Sensors and put
  it in the Secret, a sensor before the state-directory release still
  prefers the file: delete `sensor-credentials.json` from the state volume
  (newer sensors notice the changed key themselves). `sensor.keyAutoRenew:
  false` keeps the old behaviour.
- **`sensor.mode: platform` is removed** with `sensor.bootstrapToken`,
  `sensor.name`, `sensor.maxConcurrent` and `sensor.executors`: it ran
  bootstrap-token self-registration, which no OpenCTEM API serves, so it
  never registered. The render fails while `sensor.mode=platform` is set,
  and an old `agent:` block without an API key fails with the same pointer:
  create a sensor under Settings → Sensors and set `sensor.apiKey` or
  `sensor.existingSecret`.

## Upgrading to 0.8.0 (admin-only organizations, bootstrap-tenant removed)

- **Behaviour change:** the API now gets `TENANT_CREATION_MODE=admin_only`
  (`api.tenantCreationMode`). Signed-in users can no longer create
  organizations; the platform administrator does, in the admin console.
  Existing organizations and memberships are unaffected. To keep the old
  behaviour set `api.tenantCreationMode: self_service`.
- **`api.bootstrapTenant` is removed**, with its Job and its
  `<fullname>-api-bootstrap-tenant` Secret (the `bootstrap-tenant` CLI is no
  longer in the API image). The render fails while
  `api.bootstrapTenant.enabled` is `true`; use `api.bootstrapAdmin.org.*`
  instead (see "First install" above) and delete the `api.bootstrapTenant`
  block from your values.
- The bootstrap-admin Job no longer swallows failures, defaults to
  `backoffLimit: 0`, and is kept after success until you delete it. It is a
  `post-install` hook, so upgrades never re-run it.

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
| `agent.image.repository: ghcr.io/openctemio/agent` (+ `tag`) | `sensor.image` (`ghcr.io/openctemio/sensor:v0.6.3`) | The frozen agent image and its tag are ignored (its `v0.2.x` tags do not exist on the sensor repository). A custom repository (mirror) is kept with its tag. |
| `agent.allowPrivateTargets: true` / `false` | `sensor.allowPrivateTargets: "1"` / `""` | Note: chart ≤ 0.4.x rendered `"true"`, which the binary ignores, so `true` never took effect. It now does; the notice says so. |
| (always `-platform` + bootstrap token) | — | Removed in 0.9.0: an `agent:` block needs `sensor.apiKey` or `sensor.existingSecret` (the API key of a sensor created under Settings → Sensors), else the render fails. |
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
