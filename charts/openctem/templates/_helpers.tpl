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
