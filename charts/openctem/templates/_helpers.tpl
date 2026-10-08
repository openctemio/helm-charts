{{/*
Expand the name of the chart.
*/}}
{{- define "openctem.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openctem.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create a component-specific app name.
*/}}
{{- define "openctem.componentFullname" -}}
{{- $component := .component -}}
{{- printf "%s-%s" (include "openctem.fullname" .context) $component | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openctem.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openctem.labels" -}}
helm.sh/chart: {{ include "openctem.chart" . }}
{{ include "openctem.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openctem.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openctem.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels for the API component
*/}}
{{- define "openctem.apiLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: api
{{- end }}

{{/*
Selector labels for the API component
*/}}
{{- define "openctem.apiSelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{/*
Labels for the UI component
*/}}
{{- define "openctem.uiLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: ui
{{- end }}

{{/*
Selector labels for the UI component
*/}}
{{- define "openctem.uiSelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: ui
{{- end }}

{{/*
Create API workload name
*/}}
{{- define "openctem.apiFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "api") }}
{{- end }}

{{/*
Create UI workload name
*/}}
{{- define "openctem.uiFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "ui") }}
{{- end }}

{{/*
Labels for the bundled sensor component
*/}}
{{- define "openctem.sensorLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: sensor
{{- end }}

{{/*
Selector labels for the bundled sensor component
*/}}
{{- define "openctem.sensorSelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: sensor
{{- end }}

{{/*
Create bundled sensor workload name
*/}}
{{- define "openctem.sensorFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "sensor") }}
{{- end }}

{{/*
Resolve the bundled sensor credential Secret name and key (the API key).
Call with: (dict "context" . "sensor" $sensor), $sensor = the resolved
"openctem.sensor" values.
*/}}
{{- define "openctem.sensorSecretName" -}}
{{- if .sensor.existingSecret }}
{{- .sensor.existingSecret }}
{{- else }}
{{- printf "%s-credentials" (include "openctem.sensorFullname" .context) }}
{{- end }}
{{- end }}
{{- define "openctem.sensorSecretKey" -}}
{{- if .sensor.existingSecretKey }}
{{- .sensor.existingSecretKey }}
{{- else }}
{{- "api-key" }}
{{- end }}
{{- end }}

{{/*
Chart defaults of the sensor: block. MUST stay identical to values.yaml
(tests/sensor-migration/run.sh fails CI on drift). Helm cannot read the
chart's own values.yaml at render time, so this copy is how the legacy
agent: mapping below tells which sensor.* keys the user actually set.
*/}}
{{- define "openctem.sensorDefaults" -}}
enabled: false
mode: daemon
replicaCount: 1
image:
  repository: ghcr.io/openctemio/sensor
  tag: v0.11.0
  pullPolicy: IfNotPresent
region: default
apiUrl: ""
name: ""
caFingerprint: ""
platformKey: ""
apiKey: ""
existingSecret: ""
existingSecretKey: ""
tools: ""
keyAutoRenew: ""
verbose: false
allowPrivateTargets: ""
scanRoots: ""
state:
  persistence:
    enabled: true
    existingClaim: ""
    size: 128Mi
    storageClass: ""
    accessModes:
      - ReadWriteOnce
content:
  persistence:
    enabled: true
    existingClaim: ""
    size: 5Gi
    storageClass: ""
    accessModes:
      - ReadWriteOnce
  emptyDirSizeLimit: ""
outbox:
  persistence:
    enabled: false
    existingClaim: ""
    size: 2Gi
    storageClass: ""
    accessModes:
      - ReadWriteOnce
    fsGroup: 999
  emptyDirSizeLimit: ""
  maxBytes: ""
  maxAge: ""
localPolicy:
  enabled: false
  existingConfigMap: ""
  existingConfigMapKey: sensor-policy.yaml
  policy: |
    apiVersion: openctem.io/sensor-policy/v1
    # What this sensor may scan (CIDRs, IPs, host names, *.domain).
    # Replace with the network owner's ranges before enabling.
    targets:
      allow: ["203.0.113.0/24"]
      deny: []
      allow_private: false
    ports:
      allow: "80,443,8000-8999"
    checks:
      allow: [scan, validate, refresh_content]
    # Platform-supplied custom templates and out-of-band callbacks: off.
    allow_custom_templates: false
    allow_interactsh: false
    rate:
      max_rps: 100
      max_job_seconds: 14400
  killSwitchFile: ""
extraEnv: []
extraVolumes: []
extraVolumeMounts: []
podAnnotations: {}
podLabels: {}
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 999
  runAsGroup: 999
  fsGroup: 999
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
netRaw: false
sandbox:
  network: auto
  seccompProfile: runtime-default
  installProfile: true
  kubeletRoot: /var/lib/kubelet
  installerImage: ""
writableDirs:
  - /tmp
writableDirsSizeLimit: ""
resources: {}
terminationGracePeriodSeconds: 45
nodeSelector: {}
tolerations: []
affinity: {}
{{- end }}

{{/*
Map one legacy agent.<path> value onto the sensor values (internal).
Takes the agent value unless the user set sensor.<path> (a value different
from the chart default) to something else, which is recorded as a conflict.
Conflicts name the keys, never the values (one may be a credential).
Call with: (dict "target" <sensor map holding the key> "key" <key>
"path" <dotted path> "value" <agent value> "default" <chart default>
"state" <dict with conflicts/mapped lists>)
*/}}
{{- define "openctem.sensorMapLegacyKey" -}}
{{- $current := index .target .key -}}
{{- if and (ne (toYaml $current) (toYaml .default)) (ne (toYaml $current) (toYaml .value)) -}}
{{- $_ := set .state "conflicts" (append .state.conflicts (printf "agent.%s and sensor.%s" .path .path)) -}}
{{- else -}}
{{- $_ := set .target .key .value -}}
{{- $_ := set .state "mapped" (append .state.mapped .path) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the effective sensor values, as YAML (use with fromYaml):

  .Values.sensor, plus the legacy .Values.agent block (chart <= 0.4.x) mapped
  key by key onto it. This is the automatic migration for an old values file:
    - agent.<key> -> sensor.<key> for every key (same names);
    - agent.image.repository/tag are dropped when they name the frozen
      ghcr.io/openctemio/agent image (its v0.2.x tags do not exist on
      ghcr.io/openctemio/sensor); a custom repository (a mirror) is kept with
      its tag;
    - agent.allowPrivateTargets true/false -> "1"/"" (the sensor only
      recognises "1");
    - chart <= 0.4.x always ran `-platform` with a bootstrap token, a mode
      removed in chart 0.9.0 (no OpenCTEM API serves it): an agent: block
      fails the render unless an API key (sensor.apiKey / agent.apiKey) or
      sensor.existingSecret (a Secret holding the API key) says what to run
      instead;
    - agent.X and sensor.X both set to different values -> the render fails,
      naming both keys but no values (the sensor binary applies the same rule
      to its AGENT_ and SENSOR_ variables).
  The result carries "_legacy" (used, mapped, dropped, notes) for NOTES.txt.
*/}}
{{/*
The sensor seccomp profile's file name under <kubelet root>/seccomp: named
by its digest, so a changed profile is a new file and rolls the pods.
*/}}
{{- define "openctem.sensorSeccompFile" -}}
openctem/sensor-{{ .Files.Get "files/seccomp/openctem-sensor.json" | sha256sum | trunc 16 }}.json
{{- end -}}

{{- define "openctem.sensor" -}}
{{- $defaults := include "openctem.sensorDefaults" . | fromYaml -}}
{{- $sensor := deepCopy (.Values.sensor | default dict) -}}
{{- $legacy := .Values.agent -}}
{{- $state := dict "conflicts" list "mapped" list "dropped" list "notes" list -}}
{{- if $legacy -}}
{{- if not (kindIs "map" $legacy) -}}
{{- fail "\n\nThe values key `agent` was renamed to `sensor` (chart 0.5.0, OpenCTEM v0.9.0) and, when present, must be a map like `sensor`.\n" -}}
{{- end -}}
{{- $legacy = deepCopy $legacy -}}
{{- if hasKey $legacy "image" -}}
{{- $li := $legacy.image | default dict -}}
{{- $repo := toString ($li.repository | default "") -}}
{{- if or (eq $repo "") (has $repo (list "ghcr.io/openctemio/agent" "docker.io/openctemio/agent" "openctemio/agent")) -}}
{{- range $k := list "repository" "tag" -}}
{{- if index $li $k -}}
{{- $_ := set $state "dropped" (append $state.dropped (printf "agent.image.%s=%s" $k (toString (index $li $k)))) -}}
{{- end -}}
{{- end -}}
{{- $li = omit $li "repository" "tag" -}}
{{- end -}}
{{- $_ := set $legacy "image" $li -}}
{{- end -}}
{{- if hasKey $legacy "allowPrivateTargets" -}}
{{- $apt := toString $legacy.allowPrivateTargets -}}
{{- if has $apt (list "true" "1") -}}
{{- if eq $apt "true" -}}
{{- $_ := set $state "notes" (append $state.notes "agent.allowPrivateTargets=true is now SENSOR_ALLOW_PRIVATE_TARGETS=1, so private (RFC1918 / ULA) targets ARE allowed. Chart <= 0.4.x rendered \"true\", which the binary ignores (it only accepts \"1\"), so they were blocked before this upgrade. Leave sensor.allowPrivateTargets empty to keep them blocked.") -}}
{{- end -}}
{{- $_ := set $legacy "allowPrivateTargets" "1" -}}
{{- else if has $apt (list "false" "0" "" "<nil>") -}}
{{- $_ := set $legacy "allowPrivateTargets" "" -}}
{{- end -}}
{{- end -}}
{{- range $k, $v := $legacy -}}
{{- $d := index $defaults $k -}}
{{- if and (eq $k "image") (kindIs "map" $v) -}}
{{- $target := index $sensor $k -}}
{{- if not (kindIs "map" $target) -}}
{{- $target = dict -}}
{{- $_ := set $sensor $k $target -}}
{{- end -}}
{{- range $k2, $v2 := $v -}}
{{- include "openctem.sensorMapLegacyKey" (dict "target" $target "key" $k2 "path" (printf "%s.%s" $k $k2) "value" $v2 "default" (index ($d | default dict) $k2) "state" $state) -}}
{{- end -}}
{{- else -}}
{{- include "openctem.sensorMapLegacyKey" (dict "target" $sensor "key" $k "path" $k "value" $v "default" $d "state" $state) -}}
{{- end -}}
{{- end -}}
{{- if $state.conflicts -}}
{{- fail (printf "\n\nThe values set both the legacy `agent:` block and `sensor:`, with different values:\n  - %s\n`agent:` was renamed to `sensor:` in chart 0.5.0 (OpenCTEM v0.9.0). Move these settings into `sensor:` and delete `agent:` (or make both agree).\n" (join "\n  - " $state.conflicts)) -}}
{{- end -}}
{{- $ownSecret := (.Values.sensor | default dict).existingSecret -}}
{{- if and $sensor.enabled (not $sensor.apiKey) (not $ownSecret) -}}
{{- fail "\n\nThe `agent:` block (chart <= 0.4.x) ran the sensor with -platform and a bootstrap token. That mode was removed in chart 0.9.0: no OpenCTEM API serves /api/v1/platform/register, so it never registered.\nMove the settings you keep into `sensor:` and delete `agent:`: without an API key the sensor then pairs (an administrator approves it under Sensors > Pair a sensor). To keep an API key, set sensor.apiKey or sensor.existingSecret (key `api-key`, or sensor.existingSecretKey); sensor.existingSecret may name the Secret agent.existingSecret used, once it holds the API key.\n" -}}
{{- end -}}
{{- end -}}
{{- if eq (toString $sensor.mode) "platform" -}}
{{- fail "\n\nsensor.mode=platform was removed in chart 0.9.0: it ran -platform self-registration with a bootstrap token, and no OpenCTEM API serves /api/v1/platform/register, so it never registered.\nUse sensor.mode=daemon (the default): the sensor pairs, or uses the API key in sensor.apiKey / sensor.existingSecret.\n" -}}
{{- end -}}
{{- if ne (toString $sensor.mode) "daemon" -}}
{{- fail (printf "\n\nsensor.mode=%q is not supported. Use \"daemon\".\n" (toString $sensor.mode)) -}}
{{- end -}}
{{- $kar := toString $sensor.keyAutoRenew -}}
{{- if has $kar (list "" "<nil>" "auto") -}}
{{- $kar = ternary "true" "false" (and (hasKey $sensor "state") (($sensor.state | default dict).persistence | default dict).enabled) -}}
{{- else if not (has $kar (list "true" "false")) -}}
{{- fail (printf "\n\nsensor.keyAutoRenew=%q is not recognised. Use true, false, or leave it empty (on exactly when sensor.state.persistence.enabled).\n" $kar) -}}
{{- end -}}
{{- $_ := set $sensor "keyAutoRenew" $kar -}}
{{- $apt := toString ($sensor.allowPrivateTargets | default "") -}}
{{- if eq $apt "false" -}}
{{- $apt = "" -}}
{{- end -}}
{{- if not (has $apt (list "" "1")) -}}
{{- fail (printf "\n\nsensor.allowPrivateTargets=%q is not recognised. Use \"1\" to allow private (RFC1918 / ULA) scan targets, or leave it empty to refuse them. The sensor treats any other value, including \"true\", as off.\n" $apt) -}}
{{- end -}}
{{- $_ := set $sensor "allowPrivateTargets" $apt -}}
{{- $_ := set $sensor "_legacy" (dict "used" (not (empty $legacy)) "mapped" $state.mapped "dropped" $state.dropped "notes" $state.notes) -}}
{{- toYaml $sensor -}}
{{- end }}

{{/*
The API's pre-rename settings (AGENT_<X>, renamed SENSOR_<X> in RFC-023 §9.5).
The API no longer reads them and refuses to start while one is set, so the
render fails first, naming the replacement.
*/}}
{{- define "openctem.apiRetiredEnv" -}}
AGENT_CONFIG_TEMPLATES_DIR: SENSOR_CONFIG_TEMPLATES_DIR
AGENT_PUBLIC_API_URL: SENSOR_PUBLIC_API_URL
AGENT_KEY_TTL: SENSOR_KEY_TTL
AGENT_LB_JOB_WEIGHT: SENSOR_LB_JOB_WEIGHT
AGENT_LB_CPU_WEIGHT: SENSOR_LB_CPU_WEIGHT
AGENT_LB_MEMORY_WEIGHT: SENSOR_LB_MEMORY_WEIGHT
AGENT_LB_DISK_IO_WEIGHT: SENSOR_LB_DISK_IO_WEIGHT
AGENT_LB_NETWORK_WEIGHT: SENSOR_LB_NETWORK_WEIGHT
AGENT_LB_MAX_DISK_THROUGHPUT_MBPS: SENSOR_LB_MAX_DISK_THROUGHPUT_MBPS
AGENT_LB_MAX_NETWORK_THROUGHPUT_MBPS: SENSOR_LB_MAX_NETWORK_THROUGHPUT_MBPS
{{- end }}

{{- define "openctem.apiExtraEnv" -}}
{{- $retired := include "openctem.apiRetiredEnv" . | fromYaml -}}
{{- $bad := list -}}
{{- range $e := .Values.api.extraEnv -}}
{{- if kindIs "map" $e -}}
{{- $name := toString ($e.name | default "") -}}
{{- if hasKey $retired $name -}}
{{- $bad = append $bad (printf "%s -> %s" $name (index $retired $name)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $bad -}}
{{- fail (printf "\n\napi.extraEnv uses retired pre-sensor names that the API no longer reads (it refuses to start with them). Rename:\n  - %s\n" (join "\n  - " $bad)) -}}
{{- end -}}
{{- toYaml (.Values.api.extraEnv | default list) -}}
{{- end }}

{{/*
Create the API service account name to use
*/}}
{{- define "openctem.apiServiceAccountName" -}}
{{- if .Values.api.serviceAccount.create }}
{{- default (include "openctem.apiFullname" .) .Values.api.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.api.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the UI service account name to use
*/}}
{{- define "openctem.uiServiceAccountName" -}}
{{- if .Values.ui.serviceAccount.create }}
{{- default (include "openctem.uiFullname" .) .Values.ui.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.ui.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the chart-managed API app secret holding APP_ENCRYPTION_KEY and
AUTH_JWT_SECRET (only the keys not sourced from an existingSecret).
*/}}
{{/*
Secret holding the API metrics token (monitoring.*).
*/}}
{{- define "openctem.metricsSecretName" -}}
{{- if .Values.monitoring.existingSecret -}}
{{- .Values.monitoring.existingSecret -}}
{{- else -}}
{{- printf "%s-metrics" (include "openctem.apiFullname" .) -}}
{{- end -}}
{{- end }}

{{- define "openctem.apiAppSecretName" -}}
{{- printf "%s-app" (include "openctem.apiFullname" .) -}}
{{- end }}

{{/*
Effective secret name / key for APP_ENCRYPTION_KEY.
*/}}
{{- define "openctem.apiEncryptionSecretName" -}}
{{- if .Values.api.encryption.existingSecret -}}
{{- .Values.api.encryption.existingSecret -}}
{{- else -}}
{{- include "openctem.apiAppSecretName" . -}}
{{- end -}}
{{- end }}
{{- define "openctem.apiEncryptionSecretKey" -}}
{{- if .Values.api.encryption.existingSecret -}}
{{- .Values.api.encryption.keyRef -}}
{{- else -}}
APP_ENCRYPTION_KEY
{{- end -}}
{{- end }}

{{/*
Effective secret name / key for AUTH_JWT_SECRET.
*/}}
{{- define "openctem.apiJwtSecretName" -}}
{{- if .Values.api.auth.existingSecret -}}
{{- .Values.api.auth.existingSecret -}}
{{- else -}}
{{- include "openctem.apiAppSecretName" . -}}
{{- end -}}
{{- end }}
{{- define "openctem.apiJwtSecretKey" -}}
{{- if .Values.api.auth.existingSecret -}}
{{- .Values.api.auth.jwtSecretKey -}}
{{- else -}}
AUTH_JWT_SECRET
{{- end -}}
{{- end }}

{{/*
Resolve the APP_ENCRYPTION_KEY value.

Precedence:
  1. explicit inline value (api.encryption.key)
  2. value already stored in the chart-managed Secret (cluster lookup, so it
     PERSISTS across upgrades and is never rotated)
  3. generate a fresh 44-char base64 key (a valid AES-256 key per api config
     validateEncryption)

FAIL-CLOSED IN PRODUCTION (api.appEnv == "production"): steps 2 and 3 are
DISALLOWED. Under GitOps (`helm template` / ArgoCD / Flux) the cluster `lookup`
returns empty on every render, so auto-generate would mint a NEW key on each
sync — rotating APP_ENCRYPTION_KEY and making all stored integration
credentials permanently undecryptable. In production we therefore REQUIRE an
explicit api.encryption.key OR api.encryption.existingSecret and fail the
render otherwise. Auto-gen/lookup convenience is kept for dev/staging only.
Call with: (dict "context" . "existingSecret" $existingSecret)
*/}}
{{- define "openctem.apiEncryptionKeyValue" -}}
{{- $ctx := .context -}}
{{- $existing := .existingSecret -}}
{{- if $ctx.Values.api.encryption.key -}}
{{- $ctx.Values.api.encryption.key -}}
{{- else if eq ($ctx.Values.api.appEnv | toString) "production" -}}
{{- fail "\n\nAPP_ENCRYPTION_KEY is required in production (api.appEnv=production).\nAuto-generation via cluster lookup is DISABLED in production because under\nGitOps (helm template/ArgoCD/Flux) the lookup returns empty and the key would\nregenerate on every sync — rotating it makes ALL stored integration\ncredentials permanently undecryptable.\nProvide ONE of:\n  - api.encryption.existingSecret  (RECOMMENDED: External Secrets Operator /\n    sealed-secrets / GitOps-friendly, key = api.encryption.keyRef), OR\n  - api.encryption.key  (explicit, STABLE value: `openssl rand -hex 32`)\nOr set api.appEnv to a non-production value for a dev/eval install.\n" -}}
{{- else if and $existing (hasKey $existing.data "APP_ENCRYPTION_KEY") -}}
{{- index $existing.data "APP_ENCRYPTION_KEY" | b64dec -}}
{{- else -}}
{{- randBytes 32 -}}
{{- end -}}
{{- end }}

{{/*
Resolve the AUTH_JWT_SECRET value. Same precedence and the same FAIL-CLOSED
production rule as the encryption key: in production an explicit
api.auth.jwtSecret or api.auth.existingSecret is REQUIRED (a rotated JWT secret
logs every user out; GitOps + lookup would rotate it on every sync). Generated
value (non-prod only) is 64 base64 chars, satisfying the >= 64 char check.
Call with: (dict "context" . "existingSecret" $existingSecret)
*/}}
{{- define "openctem.apiJwtSecretValue" -}}
{{- $ctx := .context -}}
{{- $existing := .existingSecret -}}
{{- if $ctx.Values.api.auth.jwtSecret -}}
{{- $ctx.Values.api.auth.jwtSecret -}}
{{- else if eq ($ctx.Values.api.appEnv | toString) "production" -}}
{{- fail "\n\nAUTH_JWT_SECRET is required in production (api.appEnv=production).\nAuto-generation via cluster lookup is DISABLED in production because under\nGitOps (helm template/ArgoCD/Flux) the lookup returns empty and the secret\nwould regenerate on every sync — rotating it logs every user out.\nProvide ONE of:\n  - api.auth.existingSecret  (RECOMMENDED: External Secrets Operator /\n    sealed-secrets / GitOps-friendly, key = api.auth.jwtSecretKey), OR\n  - api.auth.jwtSecret  (explicit, STABLE, >= 64 chars: `openssl rand -base64 48`)\nOr set api.appEnv to a non-production value for a dev/eval install.\n" -}}
{{- else if and $existing (hasKey $existing.data "AUTH_JWT_SECRET") -}}
{{- index $existing.data "AUTH_JWT_SECRET" | b64dec -}}
{{- else -}}
{{- randBytes 48 -}}
{{- end -}}
{{- end }}

{{/*
Resolve PostgreSQL service name when subchart is enabled.
*/}}
{{- define "openctem.postgresqlHost" -}}
{{- if .Values.postgresql.fullnameOverride -}}
{{- .Values.postgresql.fullnameOverride -}}
{{- else -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective DB host for API.
*/}}
{{- define "openctem.databaseHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- include "openctem.postgresqlHost" . -}}
{{- else -}}
{{- .Values.database.host -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective DB port for API.
*/}}
{{- define "openctem.databasePort" -}}
{{- if .Values.postgresql.enabled -}}
{{- default 5432 .Values.postgresql.primary.service.ports.postgresql -}}
{{- else -}}
{{- .Values.database.port -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective DB name for API.
*/}}
{{- define "openctem.databaseName" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.auth.database -}}
{{- else -}}
{{- .Values.database.name -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective DB user for API.
*/}}
{{- define "openctem.databaseUser" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.auth.username -}}
{{- else -}}
{{- .Values.database.auth.username -}}
{{- end -}}
{{- end }}

{{/*
Resolve secret name containing DB password.
*/}}
{{- define "openctem.dbCredentialsSecretName" -}}
{{- if .Values.postgresql.enabled -}}
{{- if .Values.postgresql.auth.existingSecret -}}
{{- .Values.postgresql.auth.existingSecret -}}
{{- else -}}
{{- include "openctem.postgresqlHost" . -}}
{{- end -}}
{{- else -}}
{{- if .Values.database.auth.existingSecret -}}
{{- .Values.database.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-db" (include "openctem.apiFullname" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve secret key containing DB password.
*/}}
{{- define "openctem.dbPasswordSecretKey" -}}
{{- if .Values.postgresql.enabled -}}
{{- default "password" .Values.postgresql.auth.secretKeys.userPasswordKey -}}
{{- else -}}
{{- .Values.database.auth.passwordKey -}}
{{- end -}}
{{- end }}

{{/*
True when the migration Jobs use a separate schema-owner role (the API's
own role then has no DDL rights).
*/}}
{{- define "openctem.dbMigratorEnabled" -}}
{{- if and (not .Values.postgresql.enabled) (or .Values.database.migrator.username .Values.database.migrator.existingSecret) -}}true{{- end -}}
{{- end }}

{{/*
Secret holding the migrator credentials.
*/}}
{{- define "openctem.dbMigratorSecretName" -}}
{{- default (include "openctem.dbCredentialsSecretName" .) .Values.database.migrator.existingSecret -}}
{{- end }}

{{/*
DB_USER / DB_PASSWORD env for the migration Jobs: the migrator when the
least-privilege split is configured, otherwise the API's credentials.
*/}}
{{- define "openctem.migrationsDbCredentialsEnv" -}}
{{- if include "openctem.dbMigratorEnabled" . }}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.dbMigratorSecretName" . }}
      key: {{ .Values.database.migrator.userKey }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.dbMigratorSecretName" . }}
      key: {{ .Values.database.migrator.passwordKey }}
{{- else }}
{{- if .Values.postgresql.enabled }}
- name: DB_USER
  value: {{ include "openctem.databaseUser" . | quote }}
{{- else }}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.dbCredentialsSecretName" . }}
      key: {{ .Values.database.auth.userKey }}
{{- end }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.dbCredentialsSecretName" . }}
      key: {{ include "openctem.dbPasswordSecretKey" . }}
{{- end }}
{{- end }}

{{/*
Resolve Redis service name when subchart is enabled.
*/}}
{{- define "openctem.redisHost" -}}
{{- if .Values.redis.fullnameOverride -}}
{{- printf "%s-master" .Values.redis.fullnameOverride -}}
{{- else -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective Redis host for API.
*/}}
{{- define "openctem.redisEffectiveHost" -}}
{{- if .Values.redis.enabled -}}
{{- include "openctem.redisHost" . -}}
{{- else -}}
{{- .Values.redisConfig.host -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective Redis port for API.
*/}}
{{- define "openctem.redisEffectivePort" -}}
{{- if .Values.redis.enabled -}}
{{- default 6379 .Values.redis.master.service.ports.redis -}}
{{- else -}}
{{- .Values.redisConfig.port -}}
{{- end -}}
{{- end }}

{{/*
Resolve effective Redis DB for API.
*/}}
{{- define "openctem.redisEffectiveDb" -}}
{{- if .Values.redis.enabled -}}
0
{{- else -}}
{{- .Values.redisConfig.db -}}
{{- end -}}
{{- end }}

{{/*
Resolve Redis password secret name.
*/}}
{{- define "openctem.redisPasswordSecretName" -}}
{{- if .Values.redis.enabled -}}
{{- if .Values.redis.auth.existingSecret -}}
{{- .Values.redis.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-redis" .Release.Name -}}
{{- end -}}
{{- else -}}
{{- if .Values.redisConfig.auth.existingSecret -}}
{{- .Values.redisConfig.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-redis" (include "openctem.apiFullname" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve Redis password secret key.
*/}}
{{- define "openctem.redisPasswordSecretKey" -}}
{{- if .Values.redis.enabled -}}
{{- default "redis-password" .Values.redis.auth.existingSecretPasswordKey -}}
{{- else -}}
{{- .Values.redisConfig.auth.passwordKey -}}
{{- end -}}
{{- end }}

{{/*
Labels for the API migrations Job.
*/}}
{{- define "openctem.apiMigrationsLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: api-migrations
{{- end }}

{{/*
Selector labels for the API migrations Job.
*/}}
{{- define "openctem.apiMigrationsSelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: api-migrations
{{- end }}

{{/*
Create API migrations Job workload name.
*/}}
{{- define "openctem.apiMigrationsFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "api-migrations") }}
{{- end }}

{{/*
Resolve fully qualified migrations image reference.
*/}}
{{- define "openctem.apiMigrationsImage" -}}
{{- $tag := .Values.api.migrations.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.api.migrations.image.repository $tag -}}
{{- end }}

{{/*
Resolve Postgres sslmode for the migrations Job.
Explicit api.migrations.sslMode wins. Otherwise: "disable" when bundled
Postgres is enabled, "require" for external DB.
*/}}
{{- define "openctem.databaseSslMode" -}}
{{- if .Values.api.migrations.sslMode -}}
{{- .Values.api.migrations.sslMode -}}
{{- else if .Values.postgresql.enabled -}}
disable
{{- else -}}
require
{{- end -}}
{{- end }}

{{/*
Build checksum source for DB-related secret refs.
*/}}
{{- define "openctem.dbSecretChecksumSource" -}}
{{- if .Values.postgresql.enabled -}}
{{- toYaml .Values.postgresql -}}
{{- else -}}
{{- if .Values.database.auth.existingSecret -}}
{{- printf "name=%s;userKey=%s;passwordKey=%s;database=%s" (include "openctem.dbCredentialsSecretName" .) .Values.database.auth.userKey .Values.database.auth.passwordKey (include "openctem.databaseName" .)  -}}
{{- else if .Values.database.auth.createSecret -}}
{{- include (print .Template.BasePath "/api-db-secret.yaml") . -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Build checksum source for Redis-related secret refs.
*/}}
{{- define "openctem.redisSecretChecksumSource" -}}
{{- if .Values.redis.enabled -}}
{{- toYaml .Values.redis -}}
{{- else -}}
{{- if .Values.redisConfig.auth.existingSecret -}}
{{- printf "name=%s;passwordKey=%s" (include "openctem.redisPasswordSecretName" .) .Values.redisConfig.auth.passwordKey -}}
{{- else if .Values.redisConfig.auth.createSecret -}}
{{- include (print .Template.BasePath "/api-redis-secret.yaml") . -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
TENANT_CREATION_MODE from api.tenantCreationMode (admin_only | self_service).
The value is validated even when api.extraEnv sets TENANT_CREATION_MODE (the
extraEnv entry then wins and this one is not rendered, so there is no
duplicate env name).
*/}}
{{- define "openctem.apiTenantCreationModeEnv" -}}
{{- $mode := toString (.Values.api.tenantCreationMode | default "admin_only") -}}
{{- if not (has $mode (list "admin_only" "self_service")) -}}
{{- fail (printf "\n\napi.tenantCreationMode=%q is not supported. Use \"admin_only\" (only the platform administrator creates organizations, the default) or \"self_service\" (any signed-in user may create organizations).\n" $mode) -}}
{{- end -}}
{{- $have := include "openctem.apiExtraEnvNames" . | fromJsonArray -}}
{{- if not (has "TENANT_CREATION_MODE" $have) -}}
{{- toYaml (list (dict "name" "TENANT_CREATION_MODE" "value" $mode)) -}}
{{- end -}}
{{- end }}

{{/*
api.bootstrapTenant (the /app/bootstrap-tenant Job) was removed in chart 0.8.0
and the CLI is no longer in the API image. Fail loudly instead of silently
skipping the first organization an existing values file still asks for.
*/}}
{{- define "openctem.validateRemovedValues" -}}
{{- if dig "bootstrapTenant" "enabled" false (.Values.api | default dict) -}}
{{- fail "\n\napi.bootstrapTenant was removed in chart 0.8.0 (the bootstrap-tenant CLI is no longer in the API image). Create the first organization with the platform-admin bootstrap instead:\n  api.bootstrapAdmin.enabled=true, api.bootstrapAdmin.email, api.bootstrapAdmin.backupEmail,\n  api.bootstrapAdmin.org.name and api.bootstrapAdmin.org.ownerEmail (org.slug / org.ownerName optional).\nThe owner gets a one-time set-password link (emailed with SMTP, otherwise in the Job log). Then remove api.bootstrapTenant from your values.\n" -}}
{{- end -}}
{{- end }}

{{/*
SENSOR_LATEST_VERSION / SENSOR_MIN_VERSION for the API (api.sensorReleaseChannel):
the latest release defaults to the bundled sensor's image tag. A name set in
api.extraEnv wins.
*/}}
{{- define "openctem.apiSensorReleaseEnv" -}}
{{- $ch := .Values.api.sensorReleaseChannel | default dict -}}
{{- $sensor := .Values.sensor | default dict -}}
{{- $image := $sensor.image | default dict -}}
{{- $latest := toString ($ch.latestVersion | default $image.tag | default "") -}}
{{- $min := toString ($ch.minVersion | default "") -}}
{{- $have := include "openctem.apiExtraEnvNames" . | fromJsonArray -}}
{{- $env := list -}}
{{- if and $latest (not (has "SENSOR_LATEST_VERSION" $have)) -}}
{{- $env = append $env (dict "name" "SENSOR_LATEST_VERSION" "value" $latest) -}}
{{- end -}}
{{- if and $min (not (has "SENSOR_MIN_VERSION" $have)) -}}
{{- $env = append $env (dict "name" "SENSOR_MIN_VERSION" "value" $min) -}}
{{- end -}}
{{- if $env -}}
{{- toYaml $env -}}
{{- end -}}
{{- end }}

{{/*
openctem.apiReplicasValidate: refuse more than one API replica unless the
operator opts in. The API's schedulers and controllers are not yet safe with
several replicas (duplicate scheduled scans, forked audit chain).
*/}}
{{- define "openctem.apiReplicasValidate" -}}
{{- $api := .Values.api | default dict -}}
{{- $replicas := int ($api.replicaCount | default 1) -}}
{{- $as := $api.autoscaling | default dict -}}
{{- $max := 1 -}}
{{- if $as.enabled -}}{{- $max = int ($as.maxReplicas | default 1) -}}{{- end -}}
{{- if and (or (gt $replicas 1) (gt $max 1)) (not $api.allowMultipleReplicas) -}}
{{- fail (printf "\n\napi: %d replica(s) / autoscaling up to %d requested, but the API is not yet safe with more than one replica: its schedulers and background controllers run in every replica, so scheduled scans fire twice and the audit hash chain forks.\nSet api.replicaCount=1 and api.autoscaling.maxReplicas=1 (or autoscaling.enabled=false).\nOnly if the API version you deploy documents multi-replica support, set api.allowMultipleReplicas=true.\n" $replicas $max) -}}
{{- end -}}
{{- end -}}


{{/*
Sensor protocol v3 (OpenCTEM RFC-059): the sensor host name without a port,
validated when the transport is on.
*/}}
{{- define "openctem.sensorPublicHostname" -}}
{{- $st := .Values.api.sensorTransport -}}
{{- if not $st.publicHost -}}
{{- fail "\n\napi.sensorTransport.publicHost is required with api.sensorTransport.enabled and a gRPC binding (e.g. sensors.example.com:443).\n" -}}
{{- end -}}
{{- (split ":" $st.publicHost)._0 -}}
{{- end }}

{{/* The sensor CA secret name (existing or chart-made). */}}
{{- define "openctem.sensorCASecret" -}}
{{- .Values.api.sensorTransport.mtls.ca.existingSecret | default (printf "%s-sensor-ca" (include "openctem.apiFullname" .)) -}}
{{- end }}
