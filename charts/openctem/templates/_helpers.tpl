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
Resolve the bundled sensor credential Secret name and key (the API key in
daemon mode, the bootstrap token in platform mode).
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
{{- else if eq .sensor.mode "platform" }}
{{- "bootstrap-token" }}
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
  tag: v0.4.2
  pullPolicy: IfNotPresent
name: ""
region: default
apiUrl: ""
apiKey: ""
bootstrapToken: ""
existingSecret: ""
existingSecretKey: ""
tools: nuclei
keyAutoRenew: false
verbose: false
allowPrivateTargets: ""
scanRoots: ""
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
maxConcurrent: 5
executors:
  recon: false
  vulnscan: true
  secrets: false
  assets: false
  pipeline: false
extraEnv: []
podAnnotations: {}
podLabels: {}
podSecurityContext: {}
securityContext: {}
resources: {}
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
    - chart <= 0.4.x always ran `-platform` with a bootstrap token, so an
      agent: block selects mode "platform" unless sensor.mode or an API key
      (sensor.apiKey / agent.apiKey) says otherwise;
    - agent.X and sensor.X both set to different values -> the render fails,
      naming both keys but no values (the sensor binary applies the same rule
      to its AGENT_ and SENSOR_ variables).
  The result carries "_legacy" (used, mapped, dropped, notes) for NOTES.txt.
*/}}
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
{{- if and (has $k (list "image" "executors")) (kindIs "map" $v) -}}
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
{{- if and $sensor.enabled (not (hasKey $legacy "mode")) (eq (toString $sensor.mode) (toString $defaults.mode)) (not $sensor.apiKey) -}}
{{- $_ := set $sensor "mode" "platform" -}}
{{- $_ := set $state "notes" (append $state.notes "sensor.mode=platform (what chart <= 0.4.x ran: -platform with the bootstrap token). The OpenCTEM API does not serve /api/v1/platform/register, so this mode cannot register. Switch to sensor.mode=daemon with the API key of a sensor created under Settings → Sensors (sensor.apiKey or sensor.existingSecret).") -}}
{{- end -}}
{{- end -}}
{{- if not (has (toString $sensor.mode) (list "daemon" "platform")) -}}
{{- fail (printf "\n\nsensor.mode=%q is not supported. Use \"daemon\" (API key) or \"platform\" (bootstrap token).\n" (toString $sensor.mode)) -}}
{{- end -}}
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
api.extraEnv with the API's renamed settings (RFC-023 §9.5) moved to their
new names: AGENT_<X> -> SENSOR_<X>. The API still reads the old names (with a
startup WARN) and refuses to start when both are set to different values, so
the same conflict fails the render here; an identical duplicate is dropped.
Entries with other names are passed through unchanged.
*/}}
{{- define "openctem.apiRenamedEnv" -}}
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
{{- $renamed := include "openctem.apiRenamedEnv" . | fromYaml -}}
{{- $byName := dict -}}
{{- range $e := .Values.api.extraEnv -}}
{{- if and (kindIs "map" $e) $e.name -}}
{{- $_ := set $byName (toString $e.name) $e -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $e := .Values.api.extraEnv -}}
{{- $name := "" -}}
{{- if kindIs "map" $e -}}
{{- $name = toString ($e.name | default "") -}}
{{- end -}}
{{- if hasKey $renamed $name -}}
{{- $new := index $renamed $name -}}
{{- if hasKey $byName $new -}}
{{- if ne (toYaml (omit $e "name")) (toYaml (omit (index $byName $new) "name")) -}}
{{- fail (printf "\n\napi.extraEnv sets both %s (the pre-rename name) and %s to different values. The API refuses to start with both; keep only %s.\n" $name $new $new) -}}
{{- end -}}
{{- else -}}
{{- $out = append $out (merge (dict "name" $new) (omit $e "name")) -}}
{{- end -}}
{{- else -}}
{{- $out = append $out $e -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
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
Resolve UI secret name.
*/}}
{{- define "openctem.uiSecretName" -}}
{{- if .Values.ui.secret.existingSecret -}}
{{- .Values.ui.secret.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "openctem.uiFullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve UI secret CSRF token value. On install: use values or generate; on upgrade: reuse existing secret value.
Call with: include "openctem.uiSecretCsrfTokenValue" (dict "context" . "existingSecret" $existingSecret)
*/}}
{{- define "openctem.uiSecretCsrfTokenValue" -}}
{{- $ctx := .context -}}
{{- $existing := .existingSecret -}}
{{- if $ctx.Values.ui.secret.csrfToken -}}
{{- $ctx.Values.ui.secret.csrfToken -}}
{{- else if and $existing (hasKey $existing.data $ctx.Values.ui.secret.csrfTokenKey) -}}
{{- index $existing.data $ctx.Values.ui.secret.csrfTokenKey | b64dec -}}
{{- else -}}
{{- randBytes 32 -}}
{{- end -}}
{{- end }}

{{/*
Build checksum source for UI secret (for pod annotation rollout trigger).
*/}}
{{- define "openctem.uiSecretChecksumSource" -}}
{{- if .Values.ui.secret.existingSecret -}}
{{- printf "name=%s" (include "openctem.uiSecretName" .) -}}
{{- else if .Values.ui.secret.createSecret -}}
{{- include (print .Template.BasePath "/ui-secret.yaml") . -}}
{{- end -}}
{{- end }}

{{/*
Name of the chart-managed API app secret holding APP_ENCRYPTION_KEY and
AUTH_JWT_SECRET (only the keys not sourced from an existingSecret).
*/}}
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
