# OpenCTEM Helm chart

Deploys the OpenCTEM API + UI, with an optional bundled sensor and optional
bundled PostgreSQL/Redis for dev/eval.

The defaults **fail closed** rather than run an insecure platform:
`api.appEnv` defaults to `production`, which makes the render refuse to run
without a stable encryption key and JWT secret, and turns the API's
`validateProduction()` into a hard boot gate (DB TLS, Redis TLS + strong
password, ≥64-char JWT secret, encryption key, secure cookies).

The defaults are **not a production configuration** by themselves:

- the bundled PostgreSQL and Redis are on (`postgresql.enabled`,
  `redis.enabled`). They have no TLS, so an API in production mode does not
  boot against them: production uses external datastores (see
  [Datastores](#datastores-bundled--deveval-only));
- `networkPolicy.enabled` is off.

Start production installs from `values-production.yaml`.

## Versions

`appVersion` is the default tag of the API, web console and migrations images,
and must be a released [OpenCTEM](https://github.com/openctemio/openctem/releases)
tag. The release workflow of `openctemio/openctem` opens the chart PR that
bumps it after each release (OpenCTEM RFC-037). CI warns when it names a tag
that does not exist (`tests/versions/check-published.sh`).

| Chart | appVersion (OpenCTEM) | Default images |
|---|---|---|
| 0.4.1 | v0.8.0 | `openctemio/api`, `openctemio/ui`, `openctemio/migrations` (Docker Hub, never published) |
| 0.5.0 – 0.22.0 | v0.9.0 | `ghcr.io/openctemio/openctem-api`, `ghcr.io/openctemio/openctem-web`, `ghcr.io/openctemio/migrations` |
| 0.22.1 | v0.9.1 | same |
| 0.22.2 – 0.23.0 | v0.9.2 | same |
| 0.23.1 | v0.9.3 | same |
| 0.23.2 | v0.9.4 | same |
| 0.23.3 | v0.9.5 | same |
| 0.23.4 | v0.9.6 | same |
| 0.23.5 – 0.24.0 and later | v0.9.7 | same |

The bundled gateway (`gateway.mode: caddy`) uses
`ghcr.io/openctemio/openctem-gateway` at the same tag (chart 0.22.0 and later).

Chart 0.4.1 (v0.8.0) names Docker Hub repositories that were never published:
deploy v0.8.0 with it and the GHCR images (`--set
api.image.repository=ghcr.io/openctemio/api --set
ui.image.repository=ghcr.io/openctemio/ui --set
api.migrations.image.repository=ghcr.io/openctemio/migrations`). Do not point
chart 0.5.0+ at v0.8.0 images: those charts rename the agent to the sensor,
which needs the v0.9.0 API.

PostgreSQL 17 or 18 with OpenCTEM v0.9.1 (chart 0.22.1) and later. v0.9.0's
migrations stop at migration 001483 on PostgreSQL 18 (it records NOT NULL
constraints that migration did not expect); a database left dirty by that is
recovered with `migrate force 1481` and `up` on v0.9.1. The bundled evaluation
database stays pinned to 17.

## Quick start (dev / eval)

```bash
helm dependency build charts/openctem
helm install octem charts/openctem \
  --set api.appEnv=development        # relax the production boot gates
```

Dev/eval uses the **bundled** Bitnami Postgres/Redis. Do not use it for real data.

## Production

Use the provided example values: create the Secrets listed at its top, fill
every `<PLACEHOLDER>`, and deploy:

```bash
helm upgrade --install openctem charts/openctem \
  -n openctem --create-namespace \
  -f charts/openctem/values-production.yaml
helm test openctem -n openctem      # API /health and /ready, UI /api/health
```

The render fails on what the API would refuse at boot in production: the
bundled Redis (no TLS), Redis without TLS or with `tlsSkipVerify`, PostgreSQL
`sslmode=disable`, insecure cookies, and external datastores without a host or
credentials. `values.schema.json` rejects unknown top-level keys and wrong
types.

### Size presets

`values-small.yaml`, `values-medium.yaml` and `values-large.yaml` set resources,
replica counts, the API's connection pool and `GOMEMLIMIT`, and sensor volume
sizes for three installation sizes. Layer one over your production values (the
later file wins):

```bash
helm upgrade --install openctem charts/openctem -n openctem \
  -f charts/openctem/values-production.yaml -f charts/openctem/values-medium.yaml
```

| Preset | Up to | API requests / limits | UI |
|---|---|---|---|
| small | 50 users, 10k assets, 3 sensors | 500m, 512Mi / 2, 2Gi | 1 replica |
| medium | 500 users, 100k assets, 20 sensors | 2, 2Gi / 4, 4Gi | 2-4 (HPA) |
| large | 5,000 users, 1M assets, 200 sensors | 4, 4Gi / 8, 8Gi | 3-8 (HPA) |

PostgreSQL and Redis are external in production: size them from the
[sizing guide](https://docs.openctem.io/install/sizing/), which also says which
figures are measured. A preset sets `api.goMemLimit` (`GOMEMLIMIT`) and
`database.maxOpenConns` (`DB_MAX_OPEN_CONNS`), never `api.extraEnv`, so your own
`api.extraEnv` list is kept; an entry for either name there wins.

Production checklist (the chart enforces / warns on most of these):

- **Replicas**: run the API with **one** replica. Its schedulers and
  background controllers run in every replica, so the chart refuses more than
  one (`api.replicaCount`, or autoscaling `maxReplicas`) unless
  `api.allowMultipleReplicas` is set, which only an API release that documents
  multi-replica support should use. Run the UI with 2 or more replicas
  (`values-production.yaml` sets 2), with a PodDisruptionBudget
  (`minAvailable: 1`) and `topologySpreadConstraints` so replicas don't
  co-locate.
- **External datastores** — set `postgresql.enabled=false` /
  `redis.enabled=false` and point `database.*` / `redisConfig.*` at managed
  Postgres/Redis with TLS (see "Datastores" below). For certificates from a
  private CA, `database.tls.ca.existingSecret` (with `sslMode: verify-full`)
  and `api.redis.ca.existingSecret` mount the CA (`PGSSLROOTCERT`,
  `REDIS_TLS_CA_FILE`).
- **Pod hardening** (defaults): non-root, read-only root filesystems (the API
  writes only `/tmp` and its attachments volume, the console `/tmp` and
  `.next/cache`), every capability dropped, seccomp `RuntimeDefault`, and no
  service account token in any pod.
- **Stable secrets** — see "Secrets & GitOps" below (required in production).
- **NetworkPolicy** — enable `networkPolicy.enabled` on a CNI that enforces it.

## First install: platform admin and first organization

OpenCTEM has no self-registration and, by default, no self-service
organizations: the **platform administrator** creates organizations. The
administrator is not a member of any
organization (it cannot see organization data); each organization has its own
owner, who invites users or configures SSO.

Bootstrap the administrators and the first organization in the install itself:

```yaml
api:
  signupMode: disabled                  # the default: no public sign-up
  bootstrapAdmin:
    enabled: true
    email: admin@example.com                # platform administrator
    backupEmail: breakglass@example.com     # break-glass backup administrator
    org:
      name: "Example Security"             # first organization
      ownerEmail: owner@example.com         # its owner (not one of the admins)
```

1. `helm install`. After the migrations, a post-install Job runs
   `/app/bootstrap-admin`. It creates both administrators, each with a
   temporary password printed **once** to the Job log, and creates the
   organization through the normal, audited organization service. The owner
   gets a one-time set-password link (valid 24h): emailed when the platform
   has an SMTP server (admin console, System > E-mail; for a headless install
   `BOOTSTRAP_SMTP_*` in `api.bootstrapAdmin.extraEnv` stores one; the link
   base is `SMTP_BASE_URL`, which `gateway.*` sets), otherwise printed in the
   Job log.
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
  -email=admin@example.com -backup-email=breakglass@example.com \
  -org-name="Example Security" -org-owner-email=owner@example.com
```

**Why the pod log and not a Secret.** Writing the credentials to a Kubernetes
Secret would need the Job's ServiceAccount (shared with the API pods) to get
create/patch on Secrets, a namespace-wide write privilege, plus a Kubernetes
client in the API image. The pod log is already protected by `pods/log` RBAC,
the passwords are temporary (they must be changed at first sign-in) and the
owner link expires in 24h.

| Value | Default | |
|---|---|---|
| `api.signupMode` | `disabled` | `SIGNUP_MODE`, the sign-up ceiling no console change can exceed. `disabled`: no public sign-up; only the platform administrator creates organizations (admin console or the bootstrap-admin org flags). `domain`: sign-up only for addresses on an organization's verified domain, who join that organization. `open`: anyone may sign up and create an organization (hosted service; see "Hosted-service sign-up"). Any other value, and the removed `api.tenantCreationMode`, fail the render. A `SIGNUP_MODE` in `api.extraEnv` wins. |
| `api.sensorReleaseChannel.latestVersion` | `""` | `SENSOR_LATEST_VERSION`: the newest sensor release. The Sensors page shows "update available" for older sensors and its install commands pin this tag. Empty: `sensor.image.tag`. An entry in `api.extraEnv` wins (`none` turns the comparison off). |
| `api.sensorReleaseChannel.minVersion` | `""` | `SENSOR_MIN_VERSION`: the oldest supported sensor release. A heartbeating sensor below it shows as degraded. Empty: no minimum. |
| `api.bootstrapAdmin.enabled` | `false` | Run the post-install bootstrap Job. |
| `api.bootstrapAdmin.email` / `name` / `role` | — / — / `super_admin` | The platform administrator. |
| `api.bootstrapAdmin.backupEmail` / `backupName` | — | The break-glass backup administrator (required unless `noBackup: true`). |
| `api.bootstrapAdmin.noBackup` / `force` | `false` | `-no-backup` (not recommended) / `-force` (delete and re-create an existing admin). |
| `api.bootstrapAdmin.org.name` / `ownerEmail` | — | The first organization and its owner. Set both or neither (the render fails otherwise). |
| `api.bootstrapAdmin.org.slug` / `ownerName` | — | Optional. Empty: derived from the name / the email. |
| `api.bootstrapAdmin.backoffLimit` / `activeDeadlineSeconds` | `0` / `300` | Job retries (0: a failure is reported once) and deadline. |

The Job also gets `APP_ENCRYPTION_KEY`, the API's `api.extraEnv`,
`api.extraEnvFrom` and gateway environment, and `api.bootstrapAdmin.extraEnv`
(only this Job): `BOOTSTRAP_SMTP_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_FROM`,
`_FROM_NAME`, `_STARTTLS` store the platform SMTP server when none is stored,
so the owner's link is e-mailed. `SMTP_HOST` and the other `SMTP_*` server
settings were removed from the API (the render fails on them in
`api.extraEnv`). It runs the binary without a shell, so values with spaces or
quotes are passed verbatim.

## Single-port gateway (one HTTPS entry point)

The chart can serve the UI **and** the REST API on one hostname and one HTTPS
port, so sensors, API clients, SCIM, webhooks and browsers all use
`https://<host>` (since chart 0.7.0). It is opt-in: `gateway.mode: none` (the
default) renders no gateway, and the per-component `api.ingress` /
`ui.ingress` / `*.httpRoute` keep working (give them a different host).

| `gateway.mode` | Renders | TLS | Routes API-key clients on any `/api/*` |
|---|---|---|---|
| `ingress` | one `Ingress` | ingress (`gateway.ingress.tls`, cert-manager) | **no**: dedicated paths only |
| `httpRoute` | one Gateway API `HTTPRoute` | the parent Gateway's listener | `Bearer oct_*` and `X-API-Key` (header matches) |
| `caddy` | Caddy `Deployment` + `Service` + `ConfigMap` + `PVC` | `internal` / `acme` / `files` / `http` | all rules |

**Routing** (the same in every mode). `files/gateway/` holds the OpenCTEM
gateway's `Caddyfile`, `planes.caddy` and `entrypoint.sh`, byte for byte from
openctemio/openctem `api/deploy/gateway/` at the commit in
`files/gateway/UPSTREAM`. `planes.caddy` is generated there from the API's
plane table (OpenCTEM RFC-041), and the `ingress` and `httpRoute` path lists
are read from it at render time, so every mode routes the same paths. Do not
edit the copies: run `scripts/sync-gateway.sh <ref>` (default `develop`). CI
(`tests/gateway/upstream.sh`) fails when a copy differs from the pinned commit
and warns when that commit is behind `develop`. The TLS mode files
(`files/gateway/modes/`) stay chart-owned.

- to the API, by plane (prefix match): sensor `/api/v2/sensor/`,
  `/api/v1/agent/`, `/api/v1/validation/evidence`; inbound `/hooks/`,
  `/api/v1/webhooks/incoming/`; `/scim/v2/`; `/api/v1/mcp`; ops `/health`,
  `/openapi.yaml`, `/docs`; the IdP-facing `/api/v1/auth/saml/` and
  `/api/v1/auth/backchannel-logout`; the browser WebSocket `/api/v1/ws`;
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
`TRUST_PROXY_HEADERS=true` and `NEXT_PUBLIC_APP_URL` (the same origin, for the
console's Content-Security-Policy). A name already in `api.extraEnv` /
`ui.extraEnv` wins.

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
| `gateway.caddy.image` | `ghcr.io/openctemio/openctem-gateway:<appVersion>` | The OpenCTEM gateway image: Caddy plus the layer4 module (`image.layer4: true`), which the sensor gRPC routing needs (below). The stock `caddy` image works with `layer4: false`. |
| `gateway.caddy.sensorGateway` | `""` | Sensor gRPC routing on port 443: `alpn` (default with `image.layer4` and a TLS mode), `passthrough`, `off` (default with the stock image or `tls.mode: http`). See [Sensor protocol v3](#sensor-protocol-v3-grpc-over-mutual-tls). |
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

## Sensor protocol v3 (gRPC over mutual TLS)

OpenCTEM RFC-059. The API serves protocol v3 by itself
(`SENSOR_TRANSPORT_V3=auto`); there is nothing to turn on:

- the **HTTPS binding** (`/api/v3/sensor`, through the normal routing) is
  always served, behind any gateway or ingress;
- the **gRPC binding** (mutual TLS, the API's `sensor-mtls` port) is
  advertised to sensors only while the API's self-probe reaches it through
  the public endpoint. The endpoint is the host and port of the public URL
  (`gateway.publicUrl`, else `APP_URL`) unless `api.sensorTransport.publicHost`
  names another. A gateway that terminates TLS for that endpoint fails the
  probe, so sensors are never sent where gRPC cannot work; they stay on HTTPS.

The chart always mounts the sensor CA (made once with `genCA`, kept across
upgrades and `helm uninstall`, or yours) and exposes the mTLS port on the API
Service. `api.sensorTransport.mode=off` is the emergency switch: no v3 at all,
every sensor back on v2 at its next call.

| Value | Default | Meaning |
|---|---|---|
| `api.sensorTransport.mode` | `auto` | `SENSOR_TRANSPORT_V3`: `auto` or `off`. |
| `api.sensorTransport.publicHost` | `""` | `SENSOR_PUBLIC_HOST`, `host:port` sensors dial for gRPC. Empty: derived from the public URL. Set it for a dedicated sensor host name or the dedicated Service's address. |
| `api.sensorTransport.mtls.port` | `8443` | The API's mTLS listener (container and Service port). |
| `api.sensorTransport.mtls.certTTL` | `168h` | Client certificate lifetime (1h..720h). |
| `api.sensorTransport.mtls.trustedProxies` | `[]` | `SENSOR_MTLS_TRUSTED_PROXIES`: CIDRs whose PROXY protocol v2 header is believed. Empty: `gateway.trustedProxies` when the bundled Caddy routes sensors, else none. |
| `api.sensorTransport.mtls.ca.existingSecret` | `""` | Your sensor CA (`tls.crt`, `tls.key`). It is not the job-signing key. |
| `api.sensorTransport.dedicatedService.*` | off | The gRPC binding on its own Service (`LoadBalancer`, port 443): a separate address or any TCP load balancer. Needs `publicHost`. Never terminate TLS in front of it. |
| `gateway.caddy.image.layer4` | `true` | The gateway image has the layer4 module (the default image does). |
| `gateway.caddy.sensorGateway` | `""` | `OPENCTEM_SENSOR_GATEWAY`: `alpn`, `passthrough` or `off`. Empty: `alpn` with `image.layer4` and a TLS mode, else `off`. |

### Deployment modes

**Bundled Caddy with the layer4 image (gRPC on the same port 443).** The
default gateway image, `ghcr.io/openctemio/openctem-gateway` (Caddy plus
caddy-l4, built from openctemio/openctem `api/deploy/gateway/Dockerfile`), has
the module, so this is the default:

```yaml
gateway:
  mode: caddy
  host: ctem.example.com          # or an IP address (tls.mode internal/files)
  trustedProxies: [10.42.0.0/16]  # sensorGateway defaults to alpn
```

A TLS connection whose ClientHello offers the ALPN id `openctem-sensor/3` is
not terminated: it passes to the API's mTLS port behind a PROXY v2 header.
Browsers, API clients and HTTPS sensors never offer that id and are served as
before. Works with one host name, an IP address or no DNS at all; no public
certificate is needed for gRPC (the API mints its server certificate from the
sensor CA, which sensors pin). The API believes the PROXY header only from
`gateway.trustedProxies` (or `mtls.trustedProxies`).

**Dedicated sensor host name** (also for sensors that do not offer the ALPN id
yet): `gateway.caddy.sensorGateway: passthrough` and
`api.sensorTransport.publicHost: sensors.example.com:443`. That name must
resolve to the gateway and differ from `gateway.host`; it is routed by SNI.

**Stock Caddy image, `ingress`, `httpRoute`, any L7 load balancer.** Nothing to
set: the probe meets the gateway's own certificate, nothing is advertised and
sensors use the HTTPS binding. Keep response buffering off for
`/api/v3/sensor` so the `Subscribe` stream flows (the bundled Caddy does).

**ingress-nginx with SSL passthrough.** It routes by SNI only, so give sensors
their own host name: start the controller with `--enable-ssl-passthrough`, set
`api.sensorTransport.publicHost: sensors.example.com:443`, and add (for
example through `extraManifests`) an Ingress for that host to the API
Service's `sensor-mtls` port:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openctem-sensors
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: sensors.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: openctem-api   # your API Service (kubectl get svc -l app.kubernetes.io/component=api)
                port:
                  name: sensor-mtls
```

No PROXY header is sent there, so leave `mtls.trustedProxies` empty. With
`networkPolicy.enabled`, the ingress controller (the
`networkPolicy.ingressController*Selector`s) may reach the mTLS port when
`publicHost` is set in `ingress`/`httpRoute` mode.

**Separate port or TCP load balancer.** `api.sensorTransport.dedicatedService`
with `publicHost` set to the address and port sensors reach it at.

**The API terminating TLS itself** (`SERVER_TLS_CERT_FILE`/`SERVER_TLS_KEY_FILE`,
one port without a proxy) is not supported by the chart yet: the web console,
the gateway, the probes and the ServiceMonitor reach the API over plain HTTP.
Use one of the modes above.

**Self-probe and egress.** The API dials its own public endpoint. With
`networkPolicy.api.egress.allowAll=false`, add that endpoint (the gateway's
load balancer address, port 443) to `networkPolicy.api.egress.extra`, or the
probe fails and sensors stay on HTTPS. NetworkPolicy opens the mTLS port to
the release's pods, to the ingress controller (passthrough Ingress) or to
everyone (dedicated Service): the client certificate is the access control.
Status: `GET /api/v1/sensors/transport` and the metric
`openctem_sensor_transport_grpc_advertised`.

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

### Least-privilege database roles

The API should never connect as the Postgres superuser. With an external
database, use two roles (OpenCTEM `api/docs/deployment/database-roles.md`):

- `openctem_migrator` owns the schema; the migration Jobs (up and down) connect
  as it (`database.migrator.*`).
- `openctem_app` may only read and write rows; the API connects as it
  (`database.auth.*`).

Create both once, as the superuser, with the bootstrap script from the
OpenCTEM repository (idempotent; re-run it after restoring a dump):

```bash
psql "postgres://postgres@db.example.com:5432/openctem" -v ON_ERROR_STOP=1 \
  -v app_password="$APP_PW" -v migrator_password="$MIGRATOR_PW" \
  -f api/deploy/postgres/least-privilege-roles.sql
```

then set `database.auth.username=openctem_app` and
`database.migrator.username=openctem_migrator` (or point
`database.migrator.existingSecret` at a Secret with `DB_MIGRATE_USER` /
`DB_MIGRATE_PASSWORD`). `values-production.yaml` does this by default. Leaving
`database.migrator` empty keeps the single-role layout, where migrations use
`database.auth`. The bundled dev Postgres has one user and ignores it.

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
helm upgrade --install openctem openctem/openctem -n openctem \
  --set api.attachments.storage=s3 \
  --set api.attachments.s3.bucket=openctem-attachments \
  --set api.attachments.s3.existingSecret=openctem-attachments-s3
# MinIO: --set api.attachments.s3.provider=minio --set api.attachments.s3.endpoint=http://minio.storage.svc:9000
```

S3 storage needs an API release with server-wide S3 support
(`STORAGE_PROVIDER=s3`); older API images ignore it
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

`networkPolicy.enabled=true` renders a default-deny-ingress baseline for the
release's pods plus allow rules for the real flows (ingress→ui, ui/test→api,
test→ui, the single-port gateway's flows, api/migrations→postgres:5432
& redis:6379, api egress). Requires a CNI that enforces NetworkPolicy. The
default-deny selects only this release's pods (`app.kubernetes.io/instance`);
a dedicated namespace is still recommended.
API egress defaults to permissive (`networkPolicy.api.egress.allowAll=true`) so
threat-intel / CVE / CT feeds keep working; pin it with
`networkPolicy.api.egress.extra` when you can enumerate those endpoints.

## Monitoring (optional)

Operator alerting on the running platform: what to watch, the alert rules
and a runbook per alert are in OpenCTEM
`api/docs/operations/monitoring.md`. On a cluster with the Prometheus
Operator:

```yaml
monitoring:
  enabled: true              # the API serves /metrics with a bearer token
  serviceMonitor:
    enabled: true
    labels: {release: kube-prometheus-stack}   # what your Prometheus selects
  prometheusRule:
    enabled: true
    labels: {release: kube-prometheus-stack}
  prometheusNamespaceSelector: {kubernetes.io/metadata.name: monitoring}  # with networkPolicy.enabled
```

- `monitoring.enabled` sets `METRICS_TOKEN` on the API from a Secret (random,
  generated once and kept across upgrades; or `monitoring.existingSecret`).
  Without it the API answers 404 on `/metrics`. The gateway never routes
  `/metrics`.
- The ServiceMonitor scrapes the API Service with that token and labels the
  job `openctem-api`, the name the rules use.
- The PrometheusRule holds the OpenCTEM groups `openctem-api`,
  `openctem-work` and `openctem-security` (`monitoring.prometheusRule.groups`)
  plus `ApiTargetDown`. The host, Postgres, Redis and container groups of the
  compose stack are left out: the cluster's own monitoring covers those. The
  rules are `files/monitoring/openctem-rules.yml`, a copy of the monorepo's
  `deploy/observability/prometheus/rules/openctem.yml` pinned in
  `files/monitoring/UPSTREAM`; refresh it with `scripts/sync-monitoring.sh <ref>`,
  never by hand (CI checks the copy).
- Route the alerts to Telegram or Slack in your Alertmanager. Labels carry no
  tenant or user data. Some rules read metrics added after OpenCTEM v0.9.0;
  with an older API image they stay silent.

## helm test

`helm test <release>` runs an in-cluster Pod that fetches the API `/health` and
`/ready` (PostgreSQL and Redis reachable) and the UI `/api/health`. Toggle with
`tests.enabled`.

## Bundled sensor (optional)

`sensor.enabled=true` runs a co-located OpenCTEM sensor (`openctemio-sensor`)
next to the API, for work the cluster can reach (public DAST, recon,
validation). Scanning an internal network still needs a remote sensor.

By default the sensor **pairs** with the platform: it has no API key, makes
its own Ed25519 key in its data volume, and logs a code and a fingerprint.
An administrator enters the code under **Sensors > Pair a sensor**, checks
that the console shows the same fingerprint, and approves it; from then on
the sensor signs every request with its key. Nothing secret goes through Helm
values or a Secret.

```bash
# 1. Enable it.
helm upgrade openctem charts/openctem -n openctem -f values.yaml \
  --set sensor.enabled=true
# 2. Read the pairing code and fingerprint, then approve it in the console
#    (Sensors > Pair a sensor). A request that expires is replaced by a new one.
kubectl -n openctem logs deploy/openctem-openctem-sensor
```

Keep the data volume (`sensor.data.persistence`, on by default; the render
fails without it while the sensor pairs): one PersistentVolumeClaim at
`/var/lib/openctem` holding `state/` (the sensor's identity: a pod without it
has to be paired again), `outbox/` (results the platform has not accepted
yet) and `content/` (the scanner cache). Back it up like a credential; the
`content/` cache can be left out.

An organization that still allows API-key sensors can use a key instead:

```bash
kubectl -n openctem create secret generic openctem-sensor --from-literal=api-key=<key>
helm upgrade openctem charts/openctem -n openctem -f values.yaml \
  --set sensor.enabled=true --set sensor.existingSecret=openctem-sensor
```

| Value | Default | Meaning |
|---|---|---|
| `sensor.mode` | `daemon` | The only mode: the sensor runs the scans the platform dispatches. The chart passes no mode flag: from sensor v0.21.0 the daemon taking platform commands is the sensor's default mode. `platform` (bootstrap-token self-registration) was removed in 0.9.0 and fails the render: no OpenCTEM API serves it. |
| `sensor.image.repository` / `.tag` | `ghcr.io/openctemio/sensor` / `v0.23.0` | The sensor is versioned separately from the platform, so the tag does not follow `appVersion`; pin a version. The newest release is v0.22.1 (`--set sensor.image.tag=v0.22.1`): from v0.22.0 a confined port scan finds open ports (on v0.23.0 it finds none), and a target the confinement kept a tool from reaching is reported as such (the platform must accept that report first: OpenCTEM v0.9.6 or later). The plain tag is the default image (`<version>-default`): nuclei with a pinned nuclei-templates release baked in, and the recon tools (subfinder, dnsx, naabu, httpx, katana). opengrep, semgrep, trivy and betterleaks run from the single-tool images (`<version>-opengrep` from v0.22.0, `-semgrep`, `-trivy`, `-betterleaks`; also `-nuclei`). See the [sensor README](https://github.com/openctemio/sensor#install). |
| `sensor.name` | empty | `SENSOR_NAME`: the name the sensor proposes when it pairs (the approving administrator may change it). Empty: the Deployment name, `<release>-openctem-sensor`. |
| `sensor.caFingerprint` / `sensor.platformKey` | empty | Pairing pins from the platform's pairing instructions (public values): `SENSOR_CA_FINGERPRINT`, the SHA-256 of the platform CA the sensor must see in the TLS chain (needs an `https` `sensor.apiUrl` with a host name), and `SENSOR_PLATFORM_KEY`, the thumbprint of the platform's pairing key. |
| `sensor.apiKey` / `sensor.existingSecret` / `sensor.existingSecretKey` | — / — / `api-key` | An API key, for an organization that allows API-key sensors. Empty (the default): the sensor pairs. Prefer `existingSecret`. |
| `sensor.tools` | empty | Optional list of the scanners the sensor offers (`-tools`), e.g. `nuclei,httpx`. Empty (recommended): every scanner installed in the image, which the sensor detects at start and reports on its heartbeat. Deprecated from sensor v0.21.0: it only narrows the detected tools and logs a warning; narrow tools with the local policy's `tools.allow` (`sensor.localPolicy`) instead. |
| `sensor.allowPrivateTargets` | empty | `"1"` sets `SENSOR_ALLOW_PRIVATE_TARGETS=1` (RFC1918 / ULA targets allowed). Empty keeps them blocked. Any other value fails the render: the sensor only recognises `1`. Reaching the in-cluster API needs nothing (the sensor's API client allows the platform's private address). |
| `sensor.scanRoots` | empty | `SENSOR_SCAN_ROOTS` for dispatched code scans; empty = `/scan`. |
| `sensor.keyAutoRenew` | empty | API key only. `SENSOR_KEY_AUTORENEW`, always rendered. Empty: on exactly when the state is on a PersistentVolumeClaim (`sensor.data.persistence.enabled`, or `sensor.state.persistence.enabled` in the split layout); `true` / `false` force it. The renewed key is kept in the state volume (`-credentials=/var/lib/openctem/state/sensor-credentials.json`), not the Secret: the renewal retires the key in the Secret, so a pod without that volume would start with a dead key. The API issues expiring keys only with `SENSOR_KEY_TTL`. |
| `sensor.storageLayout` | empty | `data`: one volume at `/var/lib/openctem` (`sensor.data`). `split`: a volume per directory (`sensor.state`, `sensor.content`, `sensor.outbox`), the layout of releases installed before 0.19.0. Empty: `split` when the release already has one of the sensor's per-directory PVCs or a per-directory `existingClaim` is set (cluster `lookup`), else `data`. Under GitOps (`helm template`: the lookup is empty) set it explicitly. See "Upgrading to 0.19.0". |
| `sensor.data.persistence.enabled` | `true` | The data layout's PersistentVolumeClaim `<release>-openctem-sensor-data` (`size` `8Gi`, `storageClass`, `accessModes`) or `existingClaim`, mounted at `/var/lib/openctem` (`state/`, `outbox/`, `content/`; the sensor creates them). It holds a credential: back it up like one. Required while the sensor pairs; requires `replicaCount: 1`, sets `Recreate` and the `fsGroup`. With an API key, `false` gives an `emptyDir` (`sensor.data.emptyDirSizeLimit`): key auto-renewal stays off and queued results are lost with the pod. Needs a sensor image without `VOLUME` declarations (v0.16.0+); with an older image the outbox and content sit on the image's anonymous volumes on top of the data volume (the outbox then lives as long as the pod, like the split layout's default emptyDir). |
| `sensor.state.persistence.enabled` | `true` | Split layout only. The sensor's state at `/var/lib/openctem/state` (`SENSOR_STATE_DIR`): its paired identity (`identity/`: private key and sensor ID), or the API key it renews on its own. A PersistentVolumeClaim `<release>-openctem-sensor-state` (`size` `128Mi`, `storageClass`, `accessModes`) or `existingClaim`. It holds a credential: back it up like one. Required while the sensor pairs. With an API key, `false` gives an `emptyDir` and key auto-renewal stays off. |
| `sensor.content.persistence.enabled` | `true` | Split layout only. Scanner content cache at `/var/lib/openctem/content` (`SENSOR_CONTENT_DIR`: trivy DB, nuclei templates, semgrep rules), so a new pod does not download it again. A PersistentVolumeClaim `<release>-openctem-sensor-content` (`size` `5Gi`) or `existingClaim`. Disposable, and kept apart from the state. `false`: an `emptyDir` (`sensor.content.emptyDirSizeLimit`). |
| `sensor.outbox.persistence.enabled` | `false` | Split layout only (its `fsGroup` applies to every sensor PVC). The sensor (v0.4.0+) keeps results in its outbox at `/var/lib/openctem/outbox` until the platform accepted them. Default: an `emptyDir`, which survives a container restart but **not** a pod deletion, reschedule or upgrade (results still queued then are lost; `helm install` prints a warning). `true` creates a PersistentVolumeClaim `<release>-openctem-sensor-outbox` (`size` `2Gi`, `storageClass`, `accessModes` `[ReadWriteOnce]`) or uses `existingClaim`; it requires `replicaCount: 1` (one sensor per outbox), sets the Deployment strategy to `Recreate`, and gives the pod `fsGroup: 999` (the image user) unless `podSecurityContext` sets one. Any sensor PVC (outbox, state, content) requires `replicaCount: 1`, sets `Recreate` and the `fsGroup`, with `fsGroupChangePolicy: OnRootMismatch` unless `podSecurityContext` sets a policy. |
| `sensor.outbox.maxBytes` / `.maxAge` / `.emptyDirSizeLimit` | empty | `SENSOR_OUTBOX_MAX_BYTES` (default `1GiB`, at most half the free space; keep it below the volume), `SENSOR_OUTBOX_MAX_AGE` (default `168h`), and the `emptyDir` size limit. |
| `sensor.localPolicy.enabled` | `false` | The sensor-local policy ([RFC-040 §5.7](https://github.com/openctemio/openctem/blob/develop/api/docs/rfcs/RFC-040-platform-sensor-mutual-distrust.md)): a read-only file set by the network owner, mounted at `/etc/openctem/sensor-policy.yaml` (`SENSOR_LOCAL_POLICY`, ConfigMap `defaultMode 0444`). The sensor refuses every job outside it (targets, ports, tools, job types, custom templates, interactsh, rate, kill switch) whatever the platform sends, and does not start when the policy is invalid. Off by default so an upgrade keeps today's behavior (the sensor reports `local_policy: absent`); **new installs should turn it on.** Keys: [`docs/LOCAL_POLICY.md`](https://github.com/openctemio/sensor/blob/main/docs/LOCAL_POLICY.md). Older sensor images ignore the file. |
| `sensor.localPolicy.policy` | example | The policy document (rendered into `<release>-openctem-sensor-policy`; changing it rolls the pod). The default mirrors the sensor's `docs/sensor-policy.example.yaml` with a documentation range (`203.0.113.0/24`): replace it. Custom templates and interactsh are off. The render fails when it is not a `openctem.io/sensor-policy/v1` document. |
| `sensor.localPolicy.existingConfigMap` / `.existingConfigMapKey` | — / `sensor-policy.yaml` | Use a ConfigMap the network owner manages (keep its RBAC away from the platform's operators) instead of `policy`. |
| `sensor.localPolicy.killSwitchFile` | empty | `SENSOR_KILL_SWITCH_FILE`: while the file exists the sensor runs no job and heartbeats "paused by local policy". Put it on a volume the host owner can write (`sensor.extraVolumes` / `extraVolumeMounts`); in-cluster, `kill_switch: true` in the policy plus a rollout does the same. |
| `sensor.podSecurityContext` | `runAsNonRoot`, uid/gid/fsGroup `999`, `fsGroupChangePolicy: OnRootMismatch`, seccomp `RuntimeDefault` | The default image runs as uid/gid 999. The single-tool images (`-nuclei`, `-trivy`, `-semgrep`, `-opengrep`, `-betterleaks`) use 1001: set `runAsUser`, `runAsGroup` and `fsGroup` to 1001 for them. `runAsNonRoot` needs the numeric `runAsUser` (the image's `USER` is a name). Keep `OnRootMismatch`: with `Always` the kubelet makes every file group-readable at each mount, and the sensor refuses an identity key its group can read, so a paired sensor would not start after its pod is replaced. |
| `sensor.securityContext` | no privilege escalation, read-only root filesystem, `drop: [ALL]` | Container hardening (RFC-040 §5.10). Set a key to `null` to drop it. |
| `sensor.sandbox.network` | `auto` | Per-task network confinement (RFC-060, `SENSOR_SANDBOX_NETWORK`): `auto` confines when the node allows it, `required` refuses to run a task unconfined, `off` never confines. |
| `sensor.sandbox.seccompProfile` | `openctem` | `openctem` (default from chart 0.23.0): run the sensor under its own seccomp profile (the runtime default plus new namespaces), installed on the nodes by a DaemonSet (`sensor.sandbox.installProfile`, `kubeletRoot`, `installerImage`), so tasks run network-confined. `runtime-default`: the runtime's profile; tasks run unconfined. |
| `sensor.verbose` | `false` | Adds `-verbose` to the sensor's arguments (more detail in its log). |
| `sensor.netRaw` | `false` | Adds the `NET_RAW` capability (naabu SYN scans, ICMP). Off: port scans use TCP connect. |
| `sensor.writableDirs` / `.writableDirsSizeLimit` | `/tmp` / empty | `emptyDir`s mounted over the read-only root filesystem. Besides its data volume the sensor writes only `/tmp`: each scan runs with its own home directory there, and `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` point the tools' configuration and cache there. Do not add `/home/openctem`: it holds the nuclei-templates release baked into the image, which the sensor scans with until its first content refresh (and for good on a host that cannot download one). |
| `sensor.extraVolumes` / `.extraVolumeMounts` | `[]` | Extra volumes for the sensor container (for example a host directory holding the kill switch file). |

## Upgrading to 0.25.0 (the platform console as its own plane)

The platform administration console moves off the public surface:

- **`admin.listener`** (on by default): the API serves the console API only on
  its own listener in the pod (`ADMIN_LISTEN_ADDR`, the pod IP and port 8081,
  plain HTTP inside the cluster) behind the `<release>-openctem-api-admin`
  Service; the main port answers 404 for `/api/v1/admin`. The UI's console
  proxy talks to it (`ADMIN_API_URL`). With `networkPolicy.enabled`, only the UI
  pods reach that port. IPv6-only pods: `admin.listener.bindPodIP=false`.
- **`admin.allowedCidrs`**: the client networks that may reach the console
  (`ADMIN_ALLOWED_CIDRS`; default private networks only). Add your office or
  VPN range, or `0.0.0.0/0` and `::/0` for an internet-facing console.
- **`admin.site`** (gateway.mode=caddy only, on by default): the bundled Caddy
  serves the console on its own site, on a second port of `gateway.host`
  (`admin.site.port`, 8444) behind the ClusterIP Service
  `<release>-openctem-gateway-admin` (reach it with
  `kubectl port-forward svc/<release>-openctem-gateway-admin 8444`, then
  `https://localhost:8444/admin`), or on its own DNS name
  (`admin.site.host`, served on port 443 by name: the browser then isolates it
  from the main site entirely). The UI then serves the console only there and
  the main site answers 404 for `/admin` and `/api/v1/admin`. Other gateway
  modes keep the console on the main host.

Administrators sign in again on the console's own sign-in page (email,
password, then the authenticator code). To keep the old layout:
`admin.listener.enabled=false` and `admin.site.enabled=false`.

## Upgrading to 0.24.0 (sign-up ceiling)

- **`api.tenantCreationMode` is removed**, replaced by `api.signupMode`
  (`SIGNUP_MODE` on the API, which refuses to start while
  `TENANT_CREATION_MODE` is set). The render fails while
  `api.tenantCreationMode` or a `TENANT_CREATION_MODE` entry in `api.extraEnv`
  is set: `admin_only` is `api.signupMode: disabled` (the default, so just
  delete the line), `self_service` is `api.signupMode: open`.
- The admin console's sign-up setting can now only keep sign-up at or below
  `api.signupMode`; existing users, organizations and sessions are unaffected.
- `SIGNUP_MODE` is read by OpenCTEM releases after v0.9.7. An older API ignores
  it and keeps public sign-up closed, whatever `api.signupMode` says.

### Hosted-service sign-up

`api.signupMode: open` verifies every self-registered address, so the API
refuses to start until the platform e-mail is set (`api.bootstrapAdmin` with
`BOOTSTRAP_SMTP_*` in `api.bootstrapAdmin.extraEnv`, or install once with
`disabled` and set System → E-mail). In production it also needs Cloudflare
Turnstile:

```yaml
api:
  signupMode: open
  extraEnv:
    - name: CAPTCHA_TURNSTILE_SITE_KEY
      value: "0x4AAAA..."
  extraEnvFrom:
    - secretRef:
        name: openctem-turnstile   # holds CAPTCHA_TURNSTILE_SECRET
```

## Upgrading to 0.23.0 (the sensor runs confined by default)

The bundled sensor now runs under its own seccomp profile
(`sensor.sandbox.seccompProfile: openctem`) and its image is v0.23.0. When the
sensor is enabled, a DaemonSet copies the profile to each node's
`<kubelet root>/seccomp/openctem/` (root, no capabilities, read-only root
filesystem, a hostPath to that directory only), and the sensor pod uses it as a
`Localhost` profile, so each tool task runs network-confined. A namespace
whose Pod Security admission refuses hostPath volumes refuses the DaemonSet:
install the profile on the nodes yourself (`sensor.sandbox.installProfile:
false`) or keep the previous behaviour with
`sensor.sandbox.seccompProfile: runtime-default` (tasks then run unconfined,
and the platform keeps jobs that need confinement for other sensors). Nothing
changes when `sensor.enabled` is false.

## Upgrading to 0.22.0 (production hardening)

- **Gateway image**: `gateway.mode: caddy` now runs
  `ghcr.io/openctemio/openctem-gateway:<appVersion>` with `image.layer4: true`,
  so the sensor gRPC binding shares port 443 (`sensorGateway` defaults to
  `alpn`). To keep the stock image, set `gateway.caddy.image.repository: caddy`,
  `tag: 2.11.4-alpine`, `layer4: false`. The gateway pod sets the namespaced
  sysctl `net.ipv4.ip_unprivileged_port_start=0` so the non-root image binds
  443 on any container runtime.
- **Read-only root filesystems** for the API and the console, with `/tmp` (and
  the console's `.next/cache`) as emptyDirs. A custom image that writes
  elsewhere needs `api.volumes` / `api.volumeMounts` (or `ui.*`) for that path.
- **No service account token** in the API, console, sensor or Job pods
  (`api.serviceAccount.automount` and `ui.serviceAccount.automount` default to
  `false`).
- **API readiness** probes `/ready` (PostgreSQL and Redis reachable); liveness
  stays `/health`. The console's probes use `/api/health`.
- **Fail-fast production render**: with `api.appEnv: production`, the bundled
  Redis, Redis without TLS or with `tlsSkipVerify`, `sslmode=disable` and
  insecure cookies fail the render, as do external datastores without a host
  or credentials.
- **`SMTP_*` in `api.extraEnv` fails the render** (the API removed those
  settings and refuses to start with them): set the SMTP server in the admin
  console, or `BOOTSTRAP_SMTP_*` in the new `api.bootstrapAdmin.extraEnv`. The
  bootstrap Job now gets `APP_ENCRYPTION_KEY`, which it needs to e-mail the
  owner's link.
- **Size presets** set `api.goMemLimit` and `database.maxOpenConns` instead
  of `api.extraEnv`; remove the two entries you copied into your own
  `api.extraEnv` (an entry there still wins).
- **Database credentials** reach the migration and bootstrap Jobs as
  `PGUSER` / `PGPASSWORD` instead of inside a URL, so passwords with `@ : / ?
  #` or spaces work.
- **Bundled datastores** (evaluation only) are pinned to
  `bitnamilegacy/postgresql:17.6.0-debian-12-r4` and
  `bitnamilegacy/redis:8.2.1-debian-12-r0` instead of the subcharts' floating
  `latest` (which moved to PostgreSQL 18). An existing evaluation release whose
  database was initialised by PostgreSQL 18 cannot start on 17: set
  `postgresql.image.tag` back, or reinstall.
- **NetworkPolicy**: the default-deny selects the release's pods only.
- **`values.schema.json`**: unknown top-level keys and wrong types fail the
  render.

## Upgrading to 0.19.0 (one sensor data volume)

New installs keep the sensor's state, outbox and content cache on ONE
PersistentVolumeClaim, `<release>-openctem-sensor-data`, mounted at
`/var/lib/openctem` (`sensor.storageLayout: data`). A release that already
has the per-directory PVCs (`-state`, `-outbox`, `-content`) keeps them:
`sensor.storageLayout` empty picks `split` when the cluster `lookup` finds
one, so `helm upgrade` never drops the volume that holds the sensor's
identity. Under GitOps (`helm template`, ArgoCD, Flux) the lookup is empty:
**set `sensor.storageLayout: split` before upgrading an existing sensor**,
or the render switches to a new, empty data volume and the old PVCs are
pruned (a paired sensor would have to pair again).

To move an existing sensor to one volume (optional; the split layout keeps
working), with `S` the sensor's name (`<release>-openctem-sensor`):

1. Back up the `$S-state` claim, then stop the sensor:
   `kubectl -n openctem scale deploy/$S --replicas=0`.
2. Create a claim Helm does not own, copy `state/` and `outbox/` into it
   (`content/` is downloaded again), and give its root to the sensor's user:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: {name: sensor-data}
   spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 8Gi}}}
   ---
   apiVersion: v1
   kind: Pod
   metadata: {name: sensor-copy}
   spec:
     restartPolicy: Never
     containers:
       - name: copy
         image: alpine
         command: ["sh", "-c", "for d in state outbox; do mkdir -p /to/$d && cp -a /old-$d/. /to/$d/; done; chown $(stat -c %u:%g /to/state) /to"]
         volumeMounts:
           - {name: state, mountPath: /old-state, readOnly: true}
           - {name: outbox, mountPath: /old-outbox, readOnly: true}
           - {name: data, mountPath: /to}
     volumes:
       - {name: state, persistentVolumeClaim: {claimName: <S>-state}}
       - {name: outbox, persistentVolumeClaim: {claimName: <S>-outbox}}   # emptyDir: {} when sensor.outbox.persistence was off
       - {name: data, persistentVolumeClaim: {claimName: sensor-data}}
   ```

3. When the pod completed, switch the release:
   `helm upgrade openctem openctem/openctem -n openctem --reuse-values --set sensor.storageLayout=data --set sensor.data.persistence.existingClaim=sensor-data`.
4. Check that the sensor comes back as the same sensor (no new pairing code
   in its log, the same sensor online under Settings → Sensors). Helm
   deletes the chart-created `-state`, `-outbox` and `-content` claims on
   that upgrade, so keep the backup from step 1 until then.

## Upgrading to 0.18.0 (sensor protocol v3 is automatic)

Breaking: needs an OpenCTEM API with automatic protocol v3 (it refuses
`SENSOR_TRANSPORT_V3_ENABLED`, which charts 0.16.0 and 0.17.0 set).

- `api.sensorTransport.enabled` and `api.sensorTransport.gatewayPassthrough`
  are removed; setting either (even `enabled: false`) fails the render.
  Remove them. v3 is served by default; to keep it off set
  `api.sensorTransport.mode: off`.
- `gatewayPassthrough: true` becomes `gateway.caddy.sensorGateway: passthrough`
  with `gateway.caddy.image.layer4: true` (keep `publicHost`). With a single
  host name, drop `publicHost` and use `alpn` (the default with the layer4
  image).
- The API now always gets the sensor CA (the chart makes and keeps
  `<release>-openctem-api-sensor-ca`, or `mtls.ca.existingSecret`) and the
  `sensor-mtls` port on its Service, unless `mode: off`.
- `api.sensorTransport.publicHost` is optional (derived from the public URL);
  `dedicatedService` needs it.
- `SENSOR_TRANSPORT_V3_ENABLED` in `api.extraEnv` fails the render.
- Gateway files re-synced from openctem (`sensors/alpn.wrappers` new; the MCP
  plane adds its OAuth paths).

## Upgrading to 0.16.0 (sensor protocol v3)

Nothing changed until `api.sensorTransport.enabled=true` (removed in 0.18.0). The gateway files
were re-synced from openctem (`files/gateway/sensors/` is new; the stock Caddy
image keeps working with the passthrough off).

## Upgrading to 0.15.0 (sensor pairing, sensor v0.11.0)

- **The bundled sensor pairs by default.** With no `sensor.apiKey` or
  `sensor.existingSecret` the render no longer fails: the sensor pairs (see
  [Bundled sensor](#bundled-sensor-optional)). Releases that set an API key
  keep using it. Pairing needs `sensor.state.persistence.enabled` (the
  default).
- **Default image `v0.11.0`** (nuclei and the recon tools), and
  **`sensor.tools` defaults to empty**: the sensor offers every scanner in the
  image instead of nuclei only. Set `sensor.tools: nuclei` to keep the old
  allowlist.
- **`sensor.writableDirs` defaults to `/tmp` only.** The old default also
  mounted empty directories over `/home/openctem`, `/scan`, `/cache` and
  `/config`, which hid the nuclei-templates release baked into the image. A
  values file that lists `/home/openctem` keeps hiding it: remove it.
- **`fsGroupChangePolicy: OnRootMismatch`** is set whenever the sensor pod has
  an `fsGroup` (unless `sensor.podSecurityContext` sets a policy): the kubelet
  no longer makes the files of the sensor volumes group-readable at every
  mount, which would make the sensor refuse its identity key after a pod
  replacement.

## Upgrading to 0.11.0 (hardened sensor, sensor-local policy)

The bundled sensor now runs hardened by default: as uid/gid 999 with
`runAsNonRoot`, seccomp `RuntimeDefault`, no privilege escalation, no
capabilities and a read-only root filesystem, with `emptyDir`s for the
directories it writes (`sensor.writableDirs`). The default image (uid 999)
needs nothing. With a single-tool image (`-nuclei`, `-trivy`, `-semgrep`,
`-betterleaks`, uid 1001) set `sensor.podSecurityContext.runAsUser`,
`runAsGroup` and `fsGroup` to `1001`. A tool that writes somewhere else needs
that directory in `sensor.writableDirs`, or
`sensor.securityContext.readOnlyRootFilesystem: false`. Naabu SYN scans need
`sensor.netRaw: true`.

**Per-task network confinement (OpenCTEM RFC-060).** The sensor runs each tool in its own network namespace. The tool's traffic leaves only through the task's egress forwarder, which admits only the task's targets.

The container runtime's default seccomp profile blocks the namespaces this needs, so from chart 0.23.0 the sensor runs under its own profile by default (`sensor.sandbox.seccompProfile: openctem`). A confined sensor (v0.19.0 or later) tells the platform so (`net.confined@1`), and the platform sends it the jobs that need confinement, such as a nuclei job with a web scope; other sensors leave those jobs queued.

How it works:

1. The sensor runs under its own Localhost profile, which is the runtime default plus `clone`/`unshare` of new namespaces. The profile file is named by its digest, so a new profile rolls the pods.
2. Let the installer DaemonSet copy the profile to each node, or set `installProfile: false` and put it in `<kubelet root>/seccomp/openctem/` yourself.
3. Make sure the node also allows unprivileged user namespaces. On Ubuntu 23.10 and later, `kernel.apparmor_restrict_unprivileged_userns=1` takes every capability away inside a new user namespace for AppArmor-unconfined processes, so confinement cannot set it up. Either use a runtime that applies its default AppArmor profile, or allow user namespaces for the sensor.
4. Check the result: the sensor reports whether each task ran confined (`network_enforced`), and its setup checklist on the Sensors page shows the `runtime.sandbox_network` check with the fix for the cause it detected.

Where a DaemonSet with a hostPath cannot run (a restricted namespace, a managed node pool), set `sensor.sandbox.seccompProfile: runtime-default`: the sensor then runs unconfined (`auto`) and the platform keeps confinement-needing jobs for other sensors.

`sensor.localPolicy` adds the sensor-local policy (off by default, so nothing
changes until you enable it). Enable it with ranges of your own: see the
values table above.

## Upgrading to 0.10.0 (attachments on a volume or S3)

The API now keeps attachments on a 10Gi ReadWriteOnce PVC at `/app/data` by
default (see [Attachment storage](#attachment-storage)); the cluster needs a
default StorageClass, or set `api.attachments.persistence.storageClass`. With a
ReadWriteOnce volume the API Deployment switches to the `Recreate` strategy
(a short gap during upgrades) unless `api.deploymentStrategy` is set.

**Several API replicas** (`api.replicaCount > 1` or autoscaling; see the
replica limit in [Production](#production)) no longer render on that default: choose
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
  `SENSOR_KEY_AUTORENEW=true` and `-credentials` in the state volume. The
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

**Values.** An old values file with `agent:` keeps working (only retired `AGENT_*`
names in `api.extraEnv` must be renamed, see the last row):

| Old (chart ≤ 0.4.x) | New | Automatic mapping |
|---|---|---|
| `agent.<key>` | `sensor.<key>` | Every key, same name. `helm upgrade` prints a deprecation notice listing them. |
| `agent.image.repository: ghcr.io/openctemio/agent` (+ `tag`) | `sensor.image` (`ghcr.io/openctemio/sensor:v0.9.1`) | The frozen agent image and its tag are ignored (its `v0.2.x` tags do not exist on the sensor repository). A custom repository (mirror) is kept with its tag. |
| `agent.allowPrivateTargets: true` / `false` | `sensor.allowPrivateTargets: "1"` / `""` | Note: chart ≤ 0.4.x rendered `"true"`, which the binary ignores, so `true` never took effect. It now does; the notice says so. |
| (always `-platform` + bootstrap token) | — | Removed in 0.9.0: an `agent:` block needs `sensor.apiKey` or `sensor.existingSecret` (the API key of a sensor created under Settings → Sensors), else the render fails. |
| `agent.existingSecret` / `existingSecretKey` | `sensor.existingSecret` / `existingSecretKey` | Used unchanged. |
| `api.extraEnv` `AGENT_*` (`AGENT_KEY_TTL`, `AGENT_PUBLIC_API_URL`, `AGENT_CONFIG_TEMPLATES_DIR`, `AGENT_LB_*`) | `SENSOR_*` | **None since chart 0.13.0:** the API no longer reads the old names and refuses to start with them, so the render fails and names each replacement. Rename them in your values. |

The render **fails**, naming the keys (never the values), only when `agent:`
and `sensor:` set the same key to different values (the same rule the sensor
applies to its environment variables), or when `api.extraEnv` uses a retired
`AGENT_*` name. A `sensor.*` value
equal to the chart default counts as unset.

**What happens to the old objects.** The `<fullname>-agent` Deployment and its
`<fullname>-agent-bootstrap` Secret are no longer part of the release, so
`helm upgrade` deletes them and creates `<fullname>-sensor` (component label
`sensor`) and `<fullname>-sensor-credentials`. A Secret you referenced with
`existingSecret` is not owned by the release and is used as is. The new pod
starts from scratch: the old pod kept its sensor credentials only in its
container filesystem.

## Values

Every value in [`values.yaml`](values.yaml), with its type, default and the
description from its `# --` comment (generated with
[helm-docs](https://github.com/norwoodj/helm-docs); see
[CONTRIBUTING.md](../../CONTRIBUTING.md)). Long defaults are in `values.yaml`.

<!-- values-table:start -->
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `admin` | object | see `values.yaml` | --------------------------------------------------------------------------- |
| `admin.allowedCidrs` | list | `["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Client networks that may reach the console (ADMIN_ALLOWED_CIDRS, and the bundled Caddy's console site). Default: private networks only. Add your office/VPN range, or 0.0.0.0/0 and ::/0 for an internet-facing console. |
| `admin.listener.bindPodIP` | bool | `true` | Bind the pod IP (a private address, as the API requires). Set false for IPv6-only pods: the listener then binds every interface with ADMIN_LISTEN_ALLOW_ALL_INTERFACES=true; enable networkPolicy so only the UI pods reach it. |
| `admin.listener.enabled` | bool | `true` | Serve the console API on its own listener in the API pod (ADMIN_LISTEN_ADDR); the main port then answers 404 for /api/v1/admin. The UI's console proxy reaches it through the <api>-admin Service. |
| `admin.listener.port` | int | `8081` | Port of the console listener (plain HTTP, cluster-internal only). |
| `admin.site.enabled` | bool | `true` | Turn the console site on (gateway.mode=caddy). |
| `admin.site.host` | string | `""` | The console's own DNS name (OPENCTEM_ADMIN_SITE=host, served on the gateway's port 443 by name). Empty: a second port of gateway.host (OPENCTEM_ADMIN_SITE=port). |
| `admin.site.port` | int | `8444` | Port of the console site in port mode. |
| `admin.site.service.type` | string | `"ClusterIP"` | Service for the console port (port mode). ClusterIP keeps it off the network: kubectl port-forward svc/<release>-gateway-admin 8444, then https://localhost:8444/admin. LoadBalancer/NodePort publish it (the allow-list above still applies). |
| `api.affinity` | object | `{}` | Pod affinity/anti-affinity. For HA, spread replicas across nodes. See topologySpreadConstraints below for a lighter-weight alternative; use one or the other. Example soft anti-affinity is in values-production.yaml. |
| `api.allowMultipleReplicas` | bool | `false` | Opt in to more than one API replica. Only set this once the deployed API version documents multi-replica support. |
| `api.appEnv` | string | `"production"` | Application environment. "production" (the secure default) turns validateProduction() into a HARD BOOT GATE: it requires DB TLS, Redis TLS + a >=32-char Redis password, a >=64-char JWT secret, an encryption key, and secure cookies — the API refuses to start otherwise. Set to "development" or "staging" ONLY as a conscious opt-out (e.g. to run the bundled, non-TLS Redis for a demo). See values-production.yaml for the required prod values. |
| `api.attachments` | object | see `values.yaml` | Uploaded attachments and finding evidence. Without this, files were written to the pod's own filesystem: lost on every restart/upgrade, and split across pods with more than one replica. |
| `api.attachments.persistence.accessModes` | list | `["ReadWriteOnce"]` | ReadWriteOnce (default) serves one replica, and the Deployment then uses the Recreate strategy unless api.deploymentStrategy is set (a rolling update could not attach the volume on another node). ReadWriteMany (NFS, CephFS, EFS, Azure Files, ...) allows several. |
| `api.attachments.persistence.enabled` | bool | `true` | PersistentVolumeClaim at /app/data. false = emptyDir (files are lost when the pod goes; single replica only). |
| `api.attachments.persistence.existingClaim` | string | `""` | Use an existing claim instead of creating one. For more than one replica it must be ReadWriteMany: list ReadWriteMany in accessModes below to confirm it. |
| `api.attachments.s3.endpoint` | string | `""` | Empty: AWS S3. Otherwise the S3 endpoint URL, e.g. http://minio.storage.svc:9000 (private addresses are allowed here: this is operator configuration, not tenant input). |
| `api.attachments.s3.existingSecret` | string | `""` | Secret holding the access key and secret key (keys below). Recommended; otherwise the chart creates one from accessKey/secretKey. |
| `api.attachments.s3.provider` | string | `"s3"` | s3 or minio (path-style addressing when endpoint is set). |
| `api.attachments.s3.region` | string | `""` | Empty: us-east-1. |
| `api.attachments.storage` | string | `"local"` | local: files on a volume mounted at /app/data (persistence below). s3: an S3-compatible bucket (AWS S3, MinIO, ...; s3.* below). Needs an API release with server-wide S3 storage (STORAGE_PROVIDER=s3, openctemio/openctem#781); older APIs ignore it and write to the pod's disk. More than one API replica (replicaCount > 1, or autoscaling with maxReplicas > 1) needs s3 or a ReadWriteMany volume: rendering fails otherwise. Switching storage later does not move existing files. |
| `api.auth.cookieSecure` | bool | `true` | AUTH_COOKIE_SECURE — must be true in production (HTTPS). |
| `api.auth.existingSecret` | string | `""` | Source AUTH_JWT_SECRET from an existing Secret instead of the chart. |
| `api.auth.jwtSecret` | string | `""` | JWT signing secret (AUTH_JWT_SECRET). STABLE across upgrades — rotating it logs every user out. Leave blank to auto-generate-once and persist (via cluster lookup); production should set an explicit value or existingSecret. Must be >= 64 characters in production. |
| `api.auth.jwtSecretKey` | string | `"AUTH_JWT_SECRET"` |  |
| `api.auth.provider` | string | `"local"` | AUTH_PROVIDER: "local" (built-in email/password, the product default), "oidc" (Keycloak) or "hybrid". "oidc"/"hybrid" additionally require the Keycloak block to be configured in production. |
| `api.autoscaling.enabled` | bool | `false` |  |
| `api.autoscaling.maxReplicas` | int | `100` |  |
| `api.autoscaling.minReplicas` | int | `1` |  |
| `api.autoscaling.targetCPUUtilizationPercentage` | int | `80` |  |
| `api.bootstrapAdmin` | object | see `values.yaml` | Bootstrap the first PLATFORM administrators (RFC-022) and, optionally, the first organization. Runs /app/bootstrap-admin as a post-install hook Job after the migrations. The primary admin and a break-glass backup super admin are each created as a sign-in account with a temporary password printed ONCE to the Job log. Both sign in on /login, enroll an authenticator when opening the admin console (/admin), and must change the temporary password first. The backup is local (never bound to the platform identity provider, exempt from "require IdP"); every sign-in with it is audited (high), logged with alert=break_glass_sign_in and emailed to the other admins (system SMTP). Store its credentials offline and test it at least every 90 days. The completed Job (and its log) is KEPT until you delete it: read the credentials with `kubectl logs job/<fullname>-api-bootstrap-admin` (the exact command is in NOTES), store them, then `kubectl delete job/...`. Re-running is safe: existing admins are left unchanged and an existing organization slug is skipped; any other error fails the Job and the release. |
| `api.bootstrapAdmin.backoffLimit` | int | `0` | Retries. 0: a failure is reported once, never retried (each attempt would print a new log the operator has to find). |
| `api.bootstrapAdmin.backupEmail` | string | `""` | Break-glass backup administrator (required unless noBackup=true). |
| `api.bootstrapAdmin.extraEnv` | list | `[]` | Extra environment for the bootstrap-admin Job only, for example BOOTSTRAP_SMTP_HOST / _PORT / _USER / _PASSWORD / _FROM, the SMTP server it stores as the platform e-mail setting when none is stored (change it later in the admin console, System > E-mail). Take the password from a Secret with valueFrom.secretKeyRef. |
| `api.bootstrapAdmin.noBackup` | bool | `false` | Skip the break-glass backup (not recommended). |
| `api.bootstrapAdmin.org` | object | `{"name":"","ownerEmail":"","ownerName":"","slug":""}` | First organization (optional). Set name AND ownerEmail together. Created through the normal, audited organization service. The owner gets a one-time set-password link (valid 24h): emailed when the platform has an SMTP server (admin console, System > E-mail, or BOOTSTRAP_SMTP_* in api.bootstrapAdmin.extraEnv; the link base is SMTP_BASE_URL, set by gateway.* or api.extraEnv), otherwise printed once to the Job log. The owner must not be one of the platform admins (admins cannot be organization members). |
| `api.bootstrapAdmin.org.name` | string | `""` | Organization name, e.g. "Acme Security". |
| `api.bootstrapAdmin.org.ownerEmail` | string | `""` | Owner's email (a new sign-in account unless it already exists). |
| `api.bootstrapAdmin.org.ownerName` | string | `""` | Owner's display name. Empty: derived from the email. |
| `api.bootstrapAdmin.org.slug` | string | `""` | URL slug. Empty: derived from the name. |
| `api.deploymentStrategy` | object | `{}` |  |
| `api.encryption.existingSecret` | string | `""` | Source APP_ENCRYPTION_KEY from an existing Secret instead of the chart. |
| `api.encryption.key` | string | `""` | APP_ENCRYPTION_KEY (AES-256-GCM) for integration credentials at rest. Without it, non-dev deployments refuse to boot; a wrong/rotated key makes all stored credentials undecryptable. STABLE across upgrades — never rotated automatically. Leave blank to auto-generate-once and persist; production should set an explicit value or existingSecret. Accepts 32 raw / 64 hex / 44 base64 chars. |
| `api.encryption.keyRef` | string | `"APP_ENCRYPTION_KEY"` |  |
| `api.extraEnv` | list | `[]` |  |
| `api.extraEnvFrom` | list | `[]` |  |
| `api.goMemLimit` | string | `""` | GOMEMLIMIT for the API (Go's soft memory limit, e.g. "1600MiB"), about 80% of resources.limits.memory, so the garbage collector works harder before the kernel OOM-kills the pod. Empty: not set. The size presets set it. A GOMEMLIMIT entry in api.extraEnv takes precedence. |
| `api.httpRoute` | object | see `values.yaml` | Expose API service via gateway-api HTTPRoute |
| `api.image.pullPolicy` | string | `"IfNotPresent"` |  |
| `api.image.repository` | string | `"ghcr.io/openctemio/openctem-api"` | API image. Published by the openctemio/openctem monorepo from v0.9.0; releases up to v0.8.0 exist only as ghcr.io/openctemio/api, which keeps receiving identical copies for a transition window. |
| `api.image.tag` | string | `""` |  |
| `api.ingress.annotations` | object | `{}` |  |
| `api.ingress.className` | string | `""` |  |
| `api.ingress.enabled` | bool | `false` |  |
| `api.ingress.hosts[0].host` | string | `"api.chart-example.local"` |  |
| `api.ingress.hosts[0].paths[0].path` | string | `"/"` |  |
| `api.ingress.hosts[0].paths[0].pathType` | string | `"ImplementationSpecific"` |  |
| `api.ingress.tls` | list | `[]` |  |
| `api.livenessProbe` | object | `{"httpGet":{"path":"/health","port":"http"}}` | /health answers while the process runs; /ready also checks PostgreSQL and Redis (503 while either is unreachable), so a pod that lost its datastores leaves the Service without being restarted. |
| `api.migrations.activeDeadlineSeconds` | int | `600` | Hard timeout for the migration Job in seconds. |
| `api.migrations.affinity` | object | `{}` |  |
| `api.migrations.backoffLimit` | int | `2` | Job backoffLimit (retries before Job is marked failed). |
| `api.migrations.downMigration` | object | `{"activeDeadlineSeconds":600,"backoffLimit":0,"enabled":false,"steps":1}` | Manual, gated DOWN-migration Job for controlled rollbacks. DISABLED by default. `helm rollback` does NOT down-migrate — it only reverts the Kubernetes manifests, leaving the DB at the NEWER schema. If the older app version is not forward-compatible with that schema you must revert the schema yourself. Enabling this renders a one-shot Job that runs `migrate ... down <steps>`. Run it deliberately (never as an automatic hook), confirm the target step count, and take a DB backup first. |
| `api.migrations.downMigration.steps` | int | `1` | Number of migrations to revert (passed to `migrate ... down N`). |
| `api.migrations.enabled` | bool | `true` | Enable the database migrations Job. |
| `api.migrations.extraArgs` | list | `[]` | Extra args appended BEFORE the "up" subcommand. |
| `api.migrations.extraEnv` | list | `[]` | Extra environment variables for the migration container. |
| `api.migrations.hooks` | object | `{"enabled":true}` | Run as a Helm hook (post-install,pre-upgrade). When false, the Job is applied as a plain resource (useful for GitOps flows). |
| `api.migrations.image.pullPolicy` | string | `"IfNotPresent"` |  |
| `api.migrations.image.repository` | string | `"ghcr.io/openctemio/migrations"` |  |
| `api.migrations.image.tag` | string | `""` | Image tag for the migrations image. Defaults to .Chart.AppVersion. |
| `api.migrations.nodeSelector` | object | `{}` |  |
| `api.migrations.podSecurityContext` | object | see `values.yaml` | Pod-level security context of the migration Jobs (up and down). migrate only reads the SQL files baked into the image and talks to Postgres, so it runs unprivileged under the "restricted" Pod Security Standard. Empty ({}) used to run it as the image's user: root. |
| `api.migrations.resources` | object | `{}` |  |
| `api.migrations.securityContext` | object | see `values.yaml` | Container-level security context of the migration Jobs. |
| `api.migrations.sslMode` | string | `""` | Override the Postgres sslmode used in the connection URL. Blank = "disable" when postgresql.enabled, otherwise "require". |
| `api.migrations.tolerations` | list | `[]` |  |
| `api.nodeSelector` | object | `{}` |  |
| `api.podAnnotations` | object | `{}` |  |
| `api.podDisruptionBudget` | object | `{"enabled":false,"maxUnavailable":"","minAvailable":1}` | Optional PodDisruptionBudget. Set minAvailable OR maxUnavailable. |
| `api.podLabels` | object | `{}` |  |
| `api.podSecurityContext` | object | see `values.yaml` | Pod-level security context (safe non-root defaults; API image runs as uid 1000). |
| `api.readinessProbe.httpGet.path` | string | `"/ready"` |  |
| `api.readinessProbe.httpGet.port` | string | `"http"` |  |
| `api.readinessProbe.timeoutSeconds` | int | `6` |  |
| `api.redis.ca` | object | `{"existingSecret":"","key":"ca.crt"}` | CA that signed the Redis server certificate, when it is not publicly trusted (REDIS_TLS_CA_FILE). A Secret in the release namespace; the chart mounts it read-only and points REDIS_TLS_CA_FILE at it. |
| `api.redis.tlsEnabled` | bool | `false` | REDIS_TLS_ENABLED. Production REQUIRES TLS. The bundled Bitnami Redis does not terminate TLS, so production must point at an external Redis with TLS (redis.enabled=false + redisConfig.*) and set this true. |
| `api.redis.tlsSkipVerify` | bool | `false` | REDIS_TLS_SKIP_VERIFY — must stay false in production. |
| `api.replicaCount` | int | `1` | Replica count. Keep 1 for now. The API runs its schedulers and background controllers in every replica and is not yet safe with more than one: with 2+ replicas scheduled scans fire twice, the audit hash chain forks and report emails are sent twice. The chart refuses more than 1 replica (replicaCount or autoscaling maxReplicas) unless allowMultipleReplicas is true. |
| `api.resources` | object | `{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | CPU requests are REQUIRED for the CPU-target HPA to function. Memory limit is 1Gi (not 512Mi): the Go API does ingest/enrichment and threat-intel loading that spikes memory; 512Mi OOM-kills under load. Tune down only if you have measured a smaller working set. |
| `api.securityContext` | object | see `values.yaml` | Container-level security context. The root filesystem is read-only: the API writes only /tmp (an emptyDir: feed chunks, uploads in flight) and, with api.attachments.storage=local, /app/data (the attachments volume). |
| `api.sensorReleaseChannel` | object | `{"latestVersion":"","minVersion":""}` | The sensor release channel the Sensors page compares each sensor's version with, and the tag the page's install commands pin. latestVersion (SENSOR_LATEST_VERSION): empty = sensor.image.tag, so the bundled sensor and the install commands run the same release. minVersion (SENSOR_MIN_VERSION): empty = no minimum; a heartbeating sensor below it shows as degraded ("version unsupported"). An entry for either name in api.extraEnv takes precedence. |
| `api.sensorTransport.dedicatedService.annotations` | object | `{}` | Service annotations (load balancer settings). |
| `api.sensorTransport.dedicatedService.enabled` | bool | `false` | Render the `<api>-sensors` Service. |
| `api.sensorTransport.dedicatedService.loadBalancerSourceRanges` | list | `[]` | Source ranges allowed to reach the load balancer. |
| `api.sensorTransport.dedicatedService.port` | int | `443` | Service port (publicHost names the port sensors dial). |
| `api.sensorTransport.dedicatedService.type` | string | `"LoadBalancer"` | LoadBalancer \| NodePort \| ClusterIP |
| `api.sensorTransport.mode` | string | `"auto"` | SENSOR_TRANSPORT_V3: `auto` serves v3 and picks the bindings itself. `off` serves no v3 at all (every sensor back to v2 at its next call): the emergency switch. |
| `api.sensorTransport.mtls.ca.existingSecret` | string | `""` | Secret (tls.crt, tls.key) with your sensor CA. Empty: the chart makes one and keeps it across upgrades and uninstall. |
| `api.sensorTransport.mtls.certTTL` | string | `"168h"` | Client certificate lifetime (1h..720h). |
| `api.sensorTransport.mtls.port` | int | `8443` | The API's mTLS listener port (container and Service). |
| `api.sensorTransport.mtls.trustedProxies` | list | `[]` | SENSOR_MTLS_TRUSTED_PROXIES: CIDRs whose PROXY protocol v2 header the mTLS listener believes. Empty: gateway.trustedProxies when the bundled Caddy routes sensors (gateway.caddy.sensorGateway alpn or passthrough), else none (the TCP peer is the sensor's address). |
| `api.sensorTransport.publicHost` | string | `""` | SENSOR_PUBLIC_HOST: host:port sensors dial for gRPC. Empty: the host and port of the public URL (gateway.publicUrl, else APP_URL), reached through the gateway's ALPN routing. Set it for a dedicated sensor host name (gateway.caddy.sensorGateway=passthrough, an ingress-nginx ssl-passthrough Ingress) or the dedicatedService address. Advertised to sensors only while the self-probe passes either way. |
| `api.service.annotations` | object | `{}` |  |
| `api.service.nodePort` | string | `nil` |  |
| `api.service.port` | int | `80` |  |
| `api.service.type` | string | `"ClusterIP"` |  |
| `api.serviceAccount.annotations` | object | `{}` |  |
| `api.serviceAccount.automount` | bool | `false` | Mount the service account token. The API never calls the Kubernetes API, so it is off: a token in the pod is a credential nobody uses. |
| `api.serviceAccount.create` | bool | `true` |  |
| `api.serviceAccount.name` | string | `""` |  |
| `api.signupMode` | string | `"disabled"` | The API's sign-up ceiling (SIGNUP_MODE); no API or admin console change can exceed it. disabled — no public sign-up: accounts come from the platform administrator, invitations or an organization's SSO, and only the platform administrator creates organizations (admin console, or api.bootstrapAdmin.org). The default, and the right setting for self-hosted and on-prem installs. domain — sign-up only for addresses on an organization's verified domain; those people join that organization (internal portals). open — anyone may sign up and create an organization (hosted service). The API refuses to start without the platform e-mail and, in production, the Turnstile keys (CAPTCHA_TURNSTILE_SITE_KEY in api.extraEnv, CAPTCHA_TURNSTILE_SECRET from a Secret in api.extraEnvFrom). A SIGNUP_MODE entry in api.extraEnv takes precedence. |
| `api.startupProbe` | object | `{"failureThreshold":30,"httpGet":{"path":"/health","port":"http"},"periodSeconds":5}` | startupProbe is ENABLED by default: first boot can be slow (app init + threat-intel load) and without it a slow start trips livenessProbe and the kubelet kills the pod in a crash loop. failureThreshold*periodSeconds = 30*5 = up to 150s of grace before liveness takes over. Set to {} to disable. |
| `api.tolerations` | list | `[]` |  |
| `api.topologySpreadConstraints` | list | `[]` | topologySpreadConstraints (values-driven, templated). Keeps the >= 2 replicas off a single node/zone. Empty by default; values-production.yaml ships a soft (ScheduleAnyway) hostname spread. Supports `tpl` for dynamic label values. |
| `api.volumeMounts` | list | `[]` |  |
| `api.volumes` | list | `[]` |  |
| `database.auth.createSecret` | bool | `true` | Create credentials secret from values below when existingSecret is not set. |
| `database.auth.existingSecret` | string | `""` | Existing secret containing DB_USER and DB_PASSWORD keys. |
| `database.auth.password` | string | `""` |  |
| `database.auth.passwordKey` | string | `"DB_PASSWORD"` |  |
| `database.auth.userKey` | string | `"DB_USER"` |  |
| `database.auth.username` | string | `""` |  |
| `database.host` | string | `""` | Settings in this section are used only when postgresql.enabled=false. |
| `database.maxOpenConns` | string | `""` | DB_MAX_OPEN_CONNS (bundled or external database): the API's pool size. Empty: the API default (25). The size presets set it; keep it below the server's max_connections. A DB_MAX_OPEN_CONNS entry in api.extraEnv takes precedence. |
| `database.migrator` | object | see `values.yaml` | Least-privilege split (openctem api/docs/deployment/database-roles.md): the API cannot change the schema. When `username` (or an existing secret) is set, the migration Jobs connect as this schema owner (openctem_migrator) and only the API keeps `database.auth` above, which should then be the DML-only role (openctem_app). Run the openctem api/deploy/postgres/least-privilege-roles.sql once as the Postgres superuser before the first install. Empty = migrations use database.auth (the old single-role layout). External databases only. |
| `database.migrator.existingSecret` | string | `""` | Existing secret holding the migrator user and password keys. Empty = the database.auth secret (created with these keys when createSecret). |
| `database.name` | string | `"openctem"` |  |
| `database.port` | int | `5432` |  |
| `database.tls.ca` | object | `{"existingSecret":"","key":"ca.crt"}` | CA that signed the PostgreSQL server certificate, for api.migrations.sslMode verify-ca / verify-full with a private CA. A Secret in the release namespace; mounted read-only into the API, the migration and bootstrap Jobs, with PGSSLROOTCERT pointing at it. |
| `extraManifests` | list | `[]` |  |
| `fullnameOverride` | string | `""` |  |
| `gateway.caddy` | object | see `values.yaml` | ------------------------------------------------------------------------- |
| `gateway.caddy.frontProxies` | list | `[]` | CIDRs of proxies IN FRONT of Caddy whose X-Forwarded-For Caddy believes (tls.mode=http behind an L7 proxy). Empty: none. |
| `gateway.caddy.image.layer4` | bool | `true` | The image carries the layer4 module. Needed by sensorGateway alpn and passthrough, and makes alpn the default (sensor gRPC and the web share port 443). |
| `gateway.caddy.image.repository` | string | `"ghcr.io/openctemio/openctem-gateway"` | The OpenCTEM gateway image (Caddy plus the caddy-l4 module, built from openctemio/openctem api/deploy/gateway/Dockerfile and published with every release). The stock caddy image works too, with layer4=false (sensors then use the HTTPS binding). |
| `gateway.caddy.image.tag` | string | `""` | Empty: the chart appVersion. |
| `gateway.caddy.maxBodySize` | string | `"256MB"` | Largest request body (the API enforces the real per-route limits). |
| `gateway.caddy.persistence.enabled` | bool | `true` | PersistentVolumeClaim for /data (certificates, ACME account, the internal CA). Keep it: losing it re-issues the internal CA and every sensor and browser must trust the new root. false = emptyDir. |
| `gateway.caddy.podSecurityContext` | object | see `values.yaml` | Caddy runs as a non-root user and binds 443/80. The pod sets the namespaced sysctl net.ipv4.ip_unprivileged_port_start=0 (a "safe" sysctl, allowed by every Pod Security Standard), so the OpenCTEM image, whose binary has no file capability, can bind them on any runtime. The stock caddy image's binary carries the file capability cap_net_bind_service, so the container keeps NET_BIND_SERVICE in its bounding set: with every capability dropped the kernel refuses to execute it. Dropping ALL and adding back only NET_BIND_SERVICE is allowed by the "restricted" Pod Security Standard. |
| `gateway.caddy.sensorGateway` | string | `""` | OPENCTEM_SENSOR_GATEWAY: how this gateway carries the sensor gRPC binding on its port 443. Empty: `alpn` when image.layer4 is true, else `off`. `alpn`: a TLS connection that offers the sensor ALPN id (openctem-sensor/3) passes through untouched to the API's mTLS listener; works with one host name or an IP address. `passthrough`: alpn, plus a dedicated sensor host name (the host of api.sensorTransport.publicHost) routed by SNI, for sensors that do not offer the id. `off`: sensors use the HTTPS binding. alpn and passthrough need image.layer4 and a TLS mode other than http. |
| `gateway.caddy.service.externalTrafficPolicy` | string | `"Local"` | Local keeps the client's source address (audit log, IP allowlists) for LoadBalancer/NodePort; Cluster SNATs it to a node address. |
| `gateway.caddy.service.http` | object | `{"enabled":false,"nodePort":null,"port":80}` | Also expose port 80 (acme: HTTP-01 + HTTP->HTTPS redirect). In tls.mode=http port 80 is the only port and is always exposed. |
| `gateway.caddy.service.type` | string | `"LoadBalancer"` | LoadBalancer \| NodePort \| ClusterIP |
| `gateway.caddy.tls.allowPlainHttp` | bool | `false` | Must be true to use tls.mode=http (no encryption between the client and this gateway unless a TLS proxy sits in front). |
| `gateway.caddy.tls.files.secretName` | string | `""` | kubernetes.io/tls Secret with tls.crt (full chain) and tls.key. |
| `gateway.caddy.tls.mode` | string | `"internal"` | internal \| acme \| files \| http internal: certificates from Caddy's own CA (LAN / IP installs). Give sensors and browsers the root (see NOTES after install). acme: Let's Encrypt (or acme.ca) for a public DNS name; needs 443 reachable from the Internet (TLS-ALPN-01), or enable service.http for HTTP-01 and the HTTP->HTTPS redirect. files: your certificate: a kubernetes.io/tls Secret (files.secretName). http: plain HTTP on port 80, ONLY behind a proxy that terminates TLS; refused unless allowPlainHttp=true. |
| `gateway.host` | string | `""` | Public hostname (DNS name, or an IP address in caddy internal/files mode). Required for every mode except caddy with tls.mode=http. |
| `gateway.httpRoute` | object | see `values.yaml` | ------------------------------------------------------------------------- |
| `gateway.httpRoute.apiKeyHeaderRouting` | bool | `true` | Route /api/* with `Authorization: Bearer oct_*` or `X-API-Key` to the API. |
| `gateway.ingress` | object | see `values.yaml` | ------------------------------------------------------------------------- |
| `gateway.ingress.annotations` | object | `{}` | Controller-specific annotations. WebSockets and large uploads usually need tuning, e.g. for ingress-nginx: nginx.ingress.kubernetes.io/proxy-body-size: "256m" nginx.ingress.kubernetes.io/proxy-read-timeout: "3600" nginx.ingress.kubernetes.io/proxy-send-timeout: "3600" |
| `gateway.ingress.tls.clusterIssuer` | string | `""` | Convenience: adds cert-manager.io/cluster-issuer (or .../issuer). |
| `gateway.ingress.tls.enabled` | bool | `true` | Terminate TLS at the ingress for `host`. |
| `gateway.ingress.tls.secretName` | string | `""` | kubernetes.io/tls Secret. Default: <fullname>-gateway-tls (which cert-manager creates when an issuer below is set). |
| `gateway.mode` | string | `"none"` | none (default; nothing changes) \| ingress \| httpRoute \| caddy |
| `gateway.publicUrl` | string | `""` | Public origin, used for APP_URL, CORS_ALLOWED_ORIGINS and SMTP_BASE_URL. Default: https://<host>. Set it when clients use a non-443 port (e.g. https://ctem.example.com:8443) or in caddy http mode. |
| `gateway.trustedProxies` | list | `[]` | REQUIRED when mode != none: CIDRs/IPs the API trusts to report the client address (SERVER_TRUSTED_PROXIES). These are the hops that connect to the API: the gateway pods (or the ingress controller / Gateway pods) and the UI pods. Pod IPs change, so give the cluster's POD CIDR, e.g. kubeadm+flannel 10.244.0.0/16, k3s 10.42.0.0/16, GKE/EKS: the VPC/pod range. kubectl cluster-info dump \| grep -m1 -- --cluster-cidr Anything outside this list is recorded as its own TCP peer, so nothing can choose the IP written to the audit log or matched by IP allowlists. |
| `global.security.allowInsecureImages` | bool | `true` | The bundled Bitnami subcharts (evaluation only) refuse images outside docker.io/bitnami unless this is true; postgresql.image and redis.image pin bitnamilegacy releases. |
| `imagePullSecrets` | list | `[]` |  |
| `monitoring.enabled` | bool | `false` | Turn on the API's /metrics (bearer token METRICS_TOKEN). Off: /metrics answers 404. The gateway never routes /metrics, whatever this says. |
| `monitoring.existingSecret` | string | `""` | Secret holding the metrics token under `metricsTokenKey`. Empty: the chart creates one with a random token, kept across upgrades. |
| `monitoring.metricsTokenKey` | string | `"metrics-token"` |  |
| `monitoring.prometheusNamespaceSelector` | object | `{}` | With networkPolicy.enabled: where Prometheus runs, allowed to reach the API port. Both empty: any namespace (set them in production). |
| `monitoring.prometheusPodSelector` | object | `{}` |  |
| `monitoring.prometheusRule.enabled` | bool | `false` | Create a PrometheusRule with the OpenCTEM alert rules (files/monitoring/openctem-rules.yml, synced from the monorepo). |
| `monitoring.prometheusRule.groups` | list | `["openctem-api","openctem-work","openctem-security"]` | Rule groups to include. The other groups of the file need the compose stack's exporters (blackbox, node, cAdvisor, Postgres, Redis); on Kubernetes the cluster's own monitoring usually covers those. |
| `monitoring.prometheusRule.labels` | object | `{}` |  |
| `monitoring.serviceMonitor.enabled` | bool | `false` | Create a ServiceMonitor (monitoring.coreos.com/v1) that scrapes the API with the token. Needs monitoring.enabled. |
| `monitoring.serviceMonitor.interval` | string | `"30s"` |  |
| `monitoring.serviceMonitor.labels` | object | `{}` | Extra labels, e.g. the `release` label your Prometheus selects on. |
| `monitoring.serviceMonitor.scrapeTimeout` | string | `"10s"` |  |
| `nameOverride` | string | `""` |  |
| `networkPolicy.api` | object | `{"egress":{"allowAll":true,"extra":[]}}` | Egress policy for the API. The API reaches out to threat-intel / CVE / Certificate-Transparency feeds over HTTPS and needs DNS. Kept permissive by default (all egress) so those feeds are not silently broken; tighten `api.egress` to explicit CIDRs/ports if your environment allows it. |
| `networkPolicy.api.egress.allowAll` | bool | `true` | Allow all egress from the API (recommended unless you can enumerate every threat-intel endpoint). When false, only the explicit rules below (DNS + the datastore rules) are permitted. |
| `networkPolicy.api.egress.extra` | list | `[]` | Extra egress rules (NetworkPolicyEgressRule objects) appended when allowAll=false. Use to pin threat-intel egress to known CIDRs. |
| `networkPolicy.enabled` | bool | `false` | Master switch for all NetworkPolicy resources in this chart. |
| `networkPolicy.ingressControllerNamespaceSelector` | object | `{}` | Label selector identifying the namespace(s) your ingress controller runs in, used to allow inbound traffic to the UI. Empty {} allows from ALL namespaces (podSelector only). Example: { kubernetes.io/metadata.name: ingress-nginx } |
| `networkPolicy.ingressControllerPodSelector` | object | `{}` | Pod selector for the ingress controller within the namespace above. |
| `postgresql.auth.database` | string | `"openctem"` |  |
| `postgresql.auth.password` | string | `""` |  |
| `postgresql.auth.username` | string | `"openctem"` |  |
| `postgresql.enabled` | bool | `true` | Deploy bundled Bitnami PostgreSQL subchart. DEV/EVAL ONLY — see note above. |
| `postgresql.image` | object | `{"repository":"bitnamilegacy/postgresql","tag":"17.6.0-debian-12-r4"}` | Pinned: the subchart's own default is the floating `latest` tag, which moved to PostgreSQL 18. OpenCTEM is tested on PostgreSQL 17 (the version the Compose stack runs). bitnamilegacy images get no more updates: one more reason to keep the bundled database to evaluation. |
| `redis.architecture` | string | `"standalone"` |  |
| `redis.auth.enabled` | bool | `true` |  |
| `redis.auth.existingSecret` | string | `""` |  |
| `redis.auth.existingSecretPasswordKey` | string | `"redis-password"` |  |
| `redis.auth.password` | string | `""` |  |
| `redis.enabled` | bool | `true` | Deploy bundled Bitnami Redis subchart. DEV/EVAL ONLY — see note above. |
| `redis.image` | object | `{"repository":"bitnamilegacy/redis","tag":"8.2.1-debian-12-r0"}` | Pinned for reproducible installs (the subchart's default is `latest`). |
| `redisConfig.auth.createSecret` | bool | `true` | Create password secret from values below when existingSecret is not set. |
| `redisConfig.auth.existingSecret` | string | `""` | Existing secret containing REDIS_PASSWORD key. |
| `redisConfig.auth.password` | string | `""` |  |
| `redisConfig.auth.passwordKey` | string | `"REDIS_PASSWORD"` |  |
| `redisConfig.db` | int | `0` |  |
| `redisConfig.host` | string | `""` | Settings in this section are used only when redis.enabled=false. |
| `redisConfig.port` | int | `6379` |  |
| `sensor.affinity` | object | `{}` |  |
| `sensor.allowPrivateTargets` | string | `""` | SENSOR_ALLOW_PRIVATE_TARGETS. Empty (default): RFC1918 / IPv6 ULA targets are refused — co-located sensors are for external-reachable work; internal scanning belongs on a remote sensor. "1": allow private targets. Loopback, link-local/IMDS and CGNAT stay blocked either way. The sensor only recognises "1", so any other value fails the render. (Reaching the in-cluster API needs no setting: since sdk-go v0.7.2 the sensor's API client allows the platform's private address.) |
| `sensor.apiKey` | string | `""` | The sensor's API key (SENSOR_API_KEY), for organizations that allow API-key sensors. Empty, with no existingSecret (the default): the sensor pairs. It makes its own key in the state volume and logs a code; an administrator enters the code under Sensors > Pair a sensor, compares the fingerprint and approves it. For production put a key in existingSecret, not here. |
| `sensor.apiUrl` | string | `""` | Override the API base URL (SENSOR_API_URL). Defaults to the in-cluster API service. It must reach the API directly: the sensor refuses redirects. |
| `sensor.caFingerprint` | string | `""` | SENSOR_CA_FINGERPRINT, from the platform's pairing instructions (a public value): the SHA-256 of the platform CA the sensor must see in the TLS chain. Needs an https apiUrl with a host name. Empty: not pinned. |
| `sensor.content.emptyDirSizeLimit` | string | `""` | emptyDir size limit when persistence is off (empty: none). |
| `sensor.content.persistence.enabled` | bool | `true` | Back the content cache with a PersistentVolumeClaim (needs replicaCount 1; switches the Deployment to Recreate). Off: an emptyDir (emptyDirSizeLimit). |
| `sensor.data` | object | see `values.yaml` | The data volume (sensor.storageLayout data) at /var/lib/openctem. It holds the sensor's private key or renewed API key: back it up like a credential (the content/ cache can be left out). Pairing needs it persistent. With an API key and persistence off it is an emptyDir and key auto-renewal stays off. |
| `sensor.data.emptyDirSizeLimit` | string | `""` | emptyDir size limit when persistence is off (empty: none). |
| `sensor.data.persistence.enabled` | bool | `true` | Back the data with a PersistentVolumeClaim (<release>-openctem-sensor-data; needs replicaCount 1, switches the Deployment to Recreate, gives the pod fsGroup sensor.outbox.persistence.fsGroup unless podSecurityContext sets one). |
| `sensor.data.persistence.existingClaim` | string | `""` | Use this pre-created claim instead of creating one. |
| `sensor.data.persistence.size` | string | `"8Gi"` | The state is tiny; the outbox is capped by sensor.outbox.maxBytes and the content cache takes most of it (the trivy DB ~1.5 GB per version). |
| `sensor.data.persistence.storageClass` | string | `""` | Empty: the cluster's default StorageClass. |
| `sensor.enabled` | bool | `false` | Enable the bundled co-located sensor. Disabled by default (opt-in). |
| `sensor.existingSecret` | string | `""` | Name of a pre-created Secret holding the API key. Takes precedence over apiKey; nothing secret is then rendered by Helm. |
| `sensor.existingSecretKey` | string | `""` | Key within the secret. Empty: "api-key". |
| `sensor.extraEnv` | list | `[]` |  |
| `sensor.extraVolumeMounts` | list | `[]` |  |
| `sensor.extraVolumes` | list | `[]` | Extra volumes and mounts for the sensor container (for example a host directory holding the kill switch file). |
| `sensor.image.pullPolicy` | string | `"IfNotPresent"` |  |
| `sensor.image.repository` | string | `"ghcr.io/openctemio/sensor"` |  |
| `sensor.image.tag` | string | `"v0.23.0"` | Sensor image tag. The sensor is versioned separately from the platform, so this does NOT follow the chart appVersion. The plain tag is the default image (the same as <version>-default): nuclei with a pinned nuclei-templates release baked in, and the recon tools subfinder, dnsx, naabu, httpx and katana. Single-tool variants are <version>-<variant>: -nuclei, -betterleaks, -semgrep, -trivy (uid 1001: see podSecurityContext). Pin a version for reproducible installs. |
| `sensor.keyAutoRenew` | string | `""` | Renew the sensor API key before it expires and when the platform asks (SENSOR_KEY_AUTORENEW). The renewed key is kept in the state volume (/var/lib/openctem/state/sensor-credentials.json), not the Secret: the renewal retires the key in the Secret. Empty (default): on exactly when state.persistence.enabled (a renewed key on an emptyDir is lost with the pod, which then starts with the retired key). true / false force it. |
| `sensor.localPolicy` | object | see `values.yaml` | The sensor-local policy (api RFC-040 §5.7): a read-only file the network owner writes, mounted at /etc/openctem/sensor-policy.yaml. The sensor refuses every job outside it (targets, ports, tools, job types, custom templates, interactsh, rate, kill switch) whatever the platform sends; a policy it cannot load stops it. Off by default so an upgrade keeps today's behavior (the sensor then reports local_policy "absent"); new installs should turn it on and replace the example ranges. Keys: docs/LOCAL_POLICY.md in openctemio/sensor. Needs sensor >= the release that ships the local policy (older images ignore the file). |
| `sensor.localPolicy.existingConfigMap` | string | `""` | A pre-created ConfigMap holding sensor-policy.yaml (kept out of this release so whoever installs the platform need not own the policy). Takes precedence over policy. |
| `sensor.localPolicy.existingConfigMapKey` | string | `"sensor-policy.yaml"` | Key of the policy in existingConfigMap. |
| `sensor.localPolicy.killSwitchFile` | string | `""` | SENSOR_KILL_SWITCH_FILE: while this file exists the sensor runs no job and heartbeats "paused by local policy". It must sit on a volume the host owner can write (extraVolumes/extraVolumeMounts); empty: none. kill_switch: true in the policy plus a rollout is the in-cluster way. |
| `sensor.localPolicy.policy` | string | see `values.yaml` | The policy document, rendered into a ConfigMap when existingConfigMap is empty. Mirrors the sensor's docs/sensor-policy.example.yaml (custom templates and interactsh off). |
| `sensor.mode` | string | `"daemon"` | How the sensor runs. Only "daemon": `-daemon -enable-commands`, running the scans the platform dispatches. It authenticates with its own key (pairing, the default) or with an API key (apiKey / existingSecret). "platform" (the bootstrap-token self-registration chart <= 0.4.x ran) was removed in chart 0.9.0: no OpenCTEM API serves /api/v1/platform/register, so it never registered. |
| `sensor.name` | string | `""` | Name the sensor proposes when it pairs (SENSOR_NAME); the administrator who approves it may change it. Empty: the sensor's Deployment name (<release>-openctem-sensor). |
| `sensor.netRaw` | bool | `false` | Add the NET_RAW capability (naabu SYN scans, ICMP). Off: port scans use TCP connect. |
| `sensor.nodeSelector` | object | `{}` |  |
| `sensor.outbox` | object | see `values.yaml` | The sensor's outbox: results kept at /var/lib/openctem/outbox until the platform accepted them. maxBytes and maxAge apply in both layouts; persistence and emptyDirSizeLimit only to storageLayout split (fsGroup to every sensor PVC). Split layout: by default it is an emptyDir, which survives a container restart but NOT a pod deletion, reschedule or upgrade: results still queued then are lost. Enable persistence for a PVC. |
| `sensor.outbox.emptyDirSizeLimit` | string | `""` | emptyDir size limit when persistence is off (empty: none). |
| `sensor.outbox.maxAge` | string | `""` | SENSOR_OUTBOX_MAX_AGE (empty: 168h). |
| `sensor.outbox.maxBytes` | string | `""` | SENSOR_OUTBOX_MAX_BYTES (empty: the sensor's default, 1GiB and at most half of the free space). Keep it below the volume size. |
| `sensor.outbox.persistence.enabled` | bool | `false` | Back the outbox with a PersistentVolumeClaim. Needs replicaCount 1 (one sensor process per outbox) and switches the Deployment to the Recreate strategy (a ReadWriteOnce volume). |
| `sensor.outbox.persistence.existingClaim` | string | `""` | Use this pre-created claim instead of creating one. |
| `sensor.outbox.persistence.fsGroup` | int | `999` | fsGroup given to the pod (unless podSecurityContext sets one) so the image's user (uid/gid 999) can write the volumes (outbox, state, content); applied when any of them is a PersistentVolumeClaim, with fsGroupChangePolicy OnRootMismatch (see podSecurityContext). |
| `sensor.outbox.persistence.storageClass` | string | `""` | Empty: the cluster's default StorageClass. |
| `sensor.platformKey` | string | `""` | SENSOR_PLATFORM_KEY, from the platform's pairing instructions (a public value): the thumbprint of the platform's pairing key; pairing refuses another key. Empty: not pinned. |
| `sensor.podAnnotations` | object | `{}` |  |
| `sensor.podLabels` | object | `{}` |  |
| `sensor.podSecurityContext` | object | see `values.yaml` | Pod security context. The sensor image runs as uid/gid 999 (the single-tool -nuclei/-trivy/-semgrep/-betterleaks images use 1001: set runAsUser/runAsGroup/fsGroup to 1001 for them). runAsNonRoot needs a numeric runAsUser because the image's USER is a name. Keep fsGroupChangePolicy OnRootMismatch: the kubelet then sets the group of a volume's files only while the volume's root lacks it (a new volume). With the default, Always, every mount makes each file group-readable, and the sensor refuses an identity key its group can read: a paired sensor would not start after its pod is replaced. |
| `sensor.region` | string | `"default"` | SENSOR_REGION reported by the sensor. |
| `sensor.replicaCount` | int | `1` |  |
| `sensor.resources` | object | `{}` |  |
| `sensor.sandbox` | object | see `values.yaml` | Per-task network confinement (OpenCTEM RFC-060): each tool runs in its own network namespace, and its traffic leaves only through the task's egress forwarder, which admits only the task's scope. |
| `sensor.sandbox.installProfile` | bool | `true` | With seccompProfile openctem: install the profile with a DaemonSet (root, no capabilities, read-only root filesystem, writes only the kubelet's seccomp/openctem directory). false: install it yourself at <kubelet root>/seccomp/openctem/<the file name the Deployment names>. |
| `sensor.sandbox.installerImage` | string | see `values.yaml` | Image of the installer: it needs sh, cp, chmod, mv and sleep. The sensor images from v0.18.0 have no shell, so the default is busybox, pinned by digest. Empty: the sensor image (releases before v0.18.0). |
| `sensor.sandbox.kubeletRoot` | string | `"/var/lib/kubelet"` | The kubelet's root directory on the nodes. |
| `sensor.sandbox.network` | string | `"auto"` | auto: confine when the node allows it, else run unconfined and report it; required: refuse to run a task unconfined; off: never. |
| `sensor.sandbox.seccompProfile` | string | `"openctem"` | openctem (default): the sensor's own profile (the runtime's default plus clone/unshare of new namespaces), installed on the nodes by a DaemonSet (installProfile) and used as a Localhost profile, so each task runs network-confined and the sensor can take jobs that need it (a web scope). The node must also allow unprivileged user namespaces (on Ubuntu 23.10+, kernel.apparmor_restrict_unprivileged_userns=0 or an AppArmor profile that permits them). runtime-default: the container runtime's seccomp profile, which blocks the namespaces confinement needs (tasks then run unconfined under auto, and fail under required); use it where a DaemonSet with a hostPath cannot run. |
| `sensor.scanRoots` | string | `""` | SENSOR_SCAN_ROOTS: ':'-separated directories that filesystem targets of dispatched code scans (betterleaks, semgrep, trivy fs) must resolve inside. Empty: the sensor's working directory (/scan in the image). |
| `sensor.securityContext` | object | see `values.yaml` | Container security context: no privilege escalation, a read-only root filesystem (the directories the sensor and its tools write are emptyDirs or the state/content/outbox volumes: see writableDirs) and no capabilities (netRaw adds NET_RAW back). |
| `sensor.state.persistence.enabled` | bool | `true` | Back the state with a PersistentVolumeClaim (needs replicaCount 1; switches the Deployment to Recreate). |
| `sensor.state.persistence.existingClaim` | string | `""` | Use this pre-created claim instead of creating one. |
| `sensor.state.persistence.storageClass` | string | `""` | Empty: the cluster's default StorageClass. |
| `sensor.storageLayout` | string | `""` | Where the sensor keeps its data. "data": ONE volume at /var/lib/openctem holding state/ (identity, renewed key), outbox/ (undelivered results) and content/ (scanner cache): sensor.data. "split": a volume per directory (sensor.state, sensor.outbox, sensor.content), the layout of releases installed before chart 0.19.0. Empty: split when the release already has one of the sensor's per-directory PVCs (or a per-directory existingClaim is set), else data. Under GitOps (helm template, where the cluster lookup is empty) set it explicitly: "split" for an existing sensor until you migrate (README "Upgrading to 0.19.0"). The data layout needs a sensor image without VOLUME declarations (v0.16.0+). |
| `sensor.terminationGracePeriodSeconds` | int | `45` | Seconds Kubernetes waits after SIGTERM. The sensor drains for up to 30s and hands unfinished work back so the platform re-queues it at once; the Kubernetes default (30) can cut that off. |
| `sensor.tolerations` | list | `[]` |  |
| `sensor.tools` | string | `""` | Optional comma-separated allowlist of the scanners the sensor offers (-tools). Empty (default): every scanner installed in the image, which the sensor detects at start and reports on its heartbeat. |
| `sensor.verbose` | bool | `false` |  |
| `sensor.writableDirs` | list | `["/tmp"]` | Writable emptyDirs mounted over the read-only root filesystem. Besides its state, content and outbox volumes the sensor writes only /tmp: each scan runs with its own home directory there, and the tools' configuration and cache go there too (XDG_CONFIG_HOME, XDG_CACHE_HOME). Do not mount over /home/openctem: it holds the nuclei-templates release baked into the image, which the sensor scans with until its first content refresh (and for good when it cannot download one). |
| `sensor.writableDirsSizeLimit` | string | `""` | emptyDir size limit of each writable directory (empty: none). |
| `tests.enabled` | bool | `true` |  |
| `tests.image.pullPolicy` | string | `"IfNotPresent"` |  |
| `tests.image.repository` | string | `"busybox"` | Small image with wget (busybox). Pinned for reproducibility. |
| `tests.image.tag` | string | `"1.37.0"` |  |
| `tests.timeoutSeconds` | int | `10` | Overall timeout (seconds) for each curl/wget probe. |
| `ui.affinity` | object | `{}` |  |
| `ui.autoscaling.enabled` | bool | `false` |  |
| `ui.autoscaling.maxReplicas` | int | `100` |  |
| `ui.autoscaling.minReplicas` | int | `1` |  |
| `ui.autoscaling.targetCPUUtilizationPercentage` | int | `80` |  |
| `ui.cacheSizeLimit` | string | `"256Mi"` | Size limit of the /app/.next/cache emptyDir (the image optimizer and fetch cache). |
| `ui.config.backendUrl` | string | `""` | keep blank to set default backend url as the internal api service |
| `ui.config.nodeEnv` | string | `"production"` |  |
| `ui.deploymentStrategy` | object | `{}` |  |
| `ui.extraEnv` | list | `[]` |  |
| `ui.extraEnvFrom` | list | `[]` |  |
| `ui.httpRoute` | object | see `values.yaml` | Expose UI service via gateway-api HTTPRoute |
| `ui.image.pullPolicy` | string | `"IfNotPresent"` |  |
| `ui.image.repository` | string | `"ghcr.io/openctemio/openctem-web"` | Web console image (web/ in openctemio/openctem). Releases up to v0.8.0 exist only as ghcr.io/openctemio/ui. |
| `ui.image.tag` | string | `""` |  |
| `ui.ingress.annotations` | object | `{}` |  |
| `ui.ingress.className` | string | `""` |  |
| `ui.ingress.enabled` | bool | `false` |  |
| `ui.ingress.hosts[0].host` | string | `"ui.chart-example.local"` |  |
| `ui.ingress.hosts[0].paths[0].path` | string | `"/"` |  |
| `ui.ingress.hosts[0].paths[0].pathType` | string | `"ImplementationSpecific"` |  |
| `ui.ingress.tls` | list | `[]` |  |
| `ui.livenessProbe` | object | `{"httpGet":{"path":"/api/health","port":"http"}}` | /api/health answers without rendering a page or calling the API. |
| `ui.nodeSelector` | object | `{}` |  |
| `ui.podAnnotations` | object | `{}` |  |
| `ui.podDisruptionBudget` | object | `{"enabled":false,"maxUnavailable":"","minAvailable":1}` | Optional PodDisruptionBudget. Set minAvailable OR maxUnavailable. |
| `ui.podLabels` | object | `{}` |  |
| `ui.podSecurityContext` | object | see `values.yaml` | Pod-level security context (UI image runs as uid 1001 "nextjs"). |
| `ui.readinessProbe.httpGet.path` | string | `"/api/health"` |  |
| `ui.readinessProbe.httpGet.port` | string | `"http"` |  |
| `ui.replicaCount` | int | `1` | Replica count. Default 1 for dev/eval. PRODUCTION should run >= 2 for HA (see values-production.yaml). Pair with podDisruptionBudget + topologySpreadConstraints when running >= 2. |
| `ui.resources` | object | `{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | CPU requests are REQUIRED for the CPU-target HPA to function. |
| `ui.securityContext` | object | see `values.yaml` | Container-level security context. The root filesystem is read-only: Next.js writes only /tmp and /app/.next/cache, both emptyDirs. |
| `ui.service.annotations` | object | `{}` |  |
| `ui.service.nodePort` | string | `nil` |  |
| `ui.service.port` | int | `80` |  |
| `ui.service.type` | string | `"ClusterIP"` |  |
| `ui.serviceAccount.annotations` | object | `{}` |  |
| `ui.serviceAccount.automount` | bool | `false` | Mount the service account token (the console never calls the Kubernetes API). |
| `ui.serviceAccount.create` | bool | `true` |  |
| `ui.serviceAccount.name` | string | `""` |  |
| `ui.startupProbe` | object | `{}` | Optional startupProbe. Empty {} disables it. |
| `ui.tolerations` | list | `[]` |  |
| `ui.topologySpreadConstraints` | list | `[]` | topologySpreadConstraints (values-driven, templated). See api section. |
| `ui.volumeMounts` | list | `[]` |  |
| `ui.volumes` | list | `[]` |  |
<!-- values-table:end -->
