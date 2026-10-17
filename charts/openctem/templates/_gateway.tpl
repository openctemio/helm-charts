{{/*
Gateway: one public HTTPS entry point for the UI and the REST API.
files/gateway/ is the OpenCTEM gateway (openctemio/openctem api/deploy/gateway,
copied by scripts/sync-gateway.sh, checked by tests/gateway/upstream.sh). The
Ingress and HTTPRoute path lists are read from its planes.caddy, which the
monorepo generates from the API's plane table (RFC-041), so every gateway mode
routes the same paths.
*/}}

{{- define "openctem.gatewayFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "gateway") }}
{{- end }}

{{- define "openctem.gatewayLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: gateway
{{- end }}

{{- define "openctem.gatewaySelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: gateway
{{- end }}

{{/*
API path prefixes (element-wise prefix match: /api/v1/mcp matches /api/v1/mcp
and /api/v1/mcp/..., never /api/v1/mcpx): every path of the `@plane_*`
matchers in files/gateway/planes.caddy, which Caddy matches as `P` and `P/*`.
The `@edge_internal` matcher (/metrics, /ready) is never routed to the API.
*/}}
{{- define "openctem.gatewayApiPrefixes" -}}
{{- $seen := dict -}}
{{- range $line := splitList "\n" (.Files.Get "files/gateway/planes.caddy") -}}
{{- $words := splitList " " (trim $line) -}}
{{- if and (gt (len $words) 2) (hasPrefix "@plane_" (first $words)) (eq (index $words 1) "path") -}}
{{- range $p := rest (rest $words) -}}
{{- if and (not (hasSuffix "/*" $p)) (not (hasKey $seen $p)) -}}
{{- $_ := set $seen $p true }}
- {{ $p }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $seen -}}
{{- fail "files/gateway/planes.caddy has no @plane_* path matchers: re-run scripts/sync-gateway.sh" -}}
{{- end -}}
{{- end }}

{{/*
The bundled Caddy's ConfigMap data: files/gateway/ as is. ConfigMap keys
cannot hold "/", so modes/<file> is stored as modes-<file> and mapped back by
the volume's items.
*/}}
{{- define "openctem.gatewayCaddyConfigData" -}}
Caddyfile: |-
{{ .Files.Get "files/gateway/Caddyfile" | indent 2 }}
planes.caddy: |-
{{ .Files.Get "files/gateway/planes.caddy" | indent 2 }}
entrypoint.sh: |-
{{ .Files.Get "files/gateway/entrypoint.sh" | indent 2 }}
servers.common: |-
{{ .Files.Get "files/gateway/servers.common" | indent 2 }}
{{- range $path, $_ := .Files.Glob "files/gateway/modes/*" }}
modes-{{ base $path }}: |-
{{ $.Files.Get $path | indent 2 }}
{{- end }}
{{- range $path, $_ := .Files.Glob "files/gateway/sensors/*" }}
sensors-{{ base $path }}: |-
{{ $.Files.Get $path | indent 2 }}
{{- end }}
{{- range $path, $_ := .Files.Glob "files/gateway/admin/*" }}
admin-{{ base $path }}: |-
{{ $.Files.Get $path | indent 2 }}
{{- end }}
{{- end }}

{{/*
admin.site.mode, validated: port | host | off. The removed admin.site.enabled
fails the render with the replacement.
*/}}
{{- define "openctem.adminSiteMode" -}}
{{- $site := .Values.admin.site -}}
{{- if hasKey $site "enabled" -}}
{{- fail "\n\nadmin.site.enabled was removed: set admin.site.mode instead (port | host | off). enabled=false is mode=off; enabled=true with admin.site.host set is mode=host, without it mode=port.\n" -}}
{{- end -}}
{{- $m := toString ($site.mode | default "port") -}}
{{- if not (has $m (list "port" "host" "off")) -}}
{{- fail (printf "\n\nadmin.site.mode=%q is not supported. Use one of: port, host, off.\n" $m) -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{/* "true" when the bundled Caddy serves the platform console's own site. */}}
{{- define "openctem.adminSiteOn" -}}
{{- if and (eq (include "openctem.gatewayMode" .) "caddy") .Values.console.enabled (ne (include "openctem.adminSiteMode" .) "off") -}}true{{- end -}}
{{- end }}

{{/* "true" when the console site is on and reached by port (not by host name). */}}
{{- define "openctem.adminSitePort" -}}
{{- if and (include "openctem.adminSiteOn" .) (eq (include "openctem.adminSiteMode" .) "port") -}}true{{- end -}}
{{- end }}

{{/* Console component names and labels. */}}
{{- define "openctem.consoleFullname" -}}
{{ include "openctem.componentFullname" (dict "context" . "component" "console") }}
{{- end }}

{{- define "openctem.consoleLabels" -}}
{{ include "openctem.labels" . }}
app.kubernetes.io/component: console
{{- end }}

{{- define "openctem.consoleSelectorLabels" -}}
{{ include "openctem.selectorLabels" . }}
app.kubernetes.io/component: console
{{- end }}

{{/*
Fail the render on console / plane settings that cannot work. Called from the
API Deployment, which every render includes.
*/}}
{{- define "openctem.consoleValidate" -}}
{{- $mode := include "openctem.adminSiteMode" . -}}
{{- $plane := toString (.Values.api.plane | default "all") -}}
{{- if not (has $plane (list "all" "tenant" "admin")) -}}
{{- fail (printf "\n\napi.plane=%q is not valid. Use all, tenant or admin.\n" $plane) -}}
{{- end -}}
{{- if ne $plane "all" -}}
{{- fail (printf "\n\napi.plane=%s: this chart runs one API Deployment, which serves both planes (all). Splitting the API into a tenant plane and a console plane needs two releases or deployments and is not supported by this chart yet.\n" $plane) -}}
{{- end -}}
{{- if and .Values.console.ingress.enabled (not .Values.console.enabled) -}}
{{- fail "\n\nconsole.ingress.enabled=true needs console.enabled=true.\n" -}}
{{- end -}}
{{- if .Values.console.ingress.enabled -}}
{{- if eq (include "openctem.gatewayMode" .) "caddy" -}}
{{- fail "\n\nconsole.ingress.enabled=true is for gateway.mode=ingress, httpRoute or none: with gateway.mode=caddy the bundled gateway serves the console site (admin.site.mode=host).\n" -}}
{{- end -}}
{{- if ne $mode "host" -}}
{{- fail "\n\nconsole.ingress.enabled=true needs admin.site.mode=host and admin.site.host (the console's own DNS name): port mode is served only by the bundled Caddy gateway (gateway.mode=caddy).\n" -}}
{{- end -}}
{{- if not .Values.console.ingress.allowedSourceRanges -}}
{{- fail "\n\nconsole.ingress.enabled=true needs console.ingress.allowedSourceRanges: the client networks that may reach the console (CIDRs, for example your office or VPN range). Without it nothing limits who reaches the console from the internet. Use [0.0.0.0/0, ::/0] only if an identity-aware proxy in front is the gate.\n" -}}
{{- end -}}
{{- if not (include "openctem.gatewayTrustedProxies" .) -}}
{{- fail "\n\nconsole.ingress.enabled=true needs gateway.trustedProxies (the CIDRs of the pods that connect to the API: the ingress controller and the console): the API takes the client address from the console only when it trusts it, and checks admin.allowedCidrs on that address.\n" -}}
{{- end -}}
{{- if not .Values.networkPolicy.enabled -}}
{{- fail "\n\nconsole.ingress.enabled=true needs networkPolicy.enabled=true: the console believes the client address its caller sends, so only the ingress controller may reach it.\n" -}}
{{- end -}}
{{- if not (or .Values.networkPolicy.ingressControllerNamespaceSelector .Values.networkPolicy.ingressControllerPodSelector) -}}
{{- fail "\n\nconsole.ingress.enabled=true needs networkPolicy.ingressControllerNamespaceSelector (and/or ingressControllerPodSelector) naming the ingress controller: the console believes the client address its caller sends.\n" -}}
{{- end -}}
{{- end -}}
{{- if .Values.console.enabled -}}
{{- $api := .Values.api | default dict -}}
{{- $as := $api.autoscaling | default dict -}}
{{- if and (or (gt (int ($api.replicaCount | default 1)) 1) $as.enabled) (not $api.auth.existingSecret) (not $api.auth.jwtSecret) -}}
{{- fail "\n\nMore than one API replica (api.replicaCount > 1, or api.autoscaling.enabled) with the console needs a session secret you set: api.auth.jwtSecret or api.auth.existingSecret. The console's CSRF tokens are signed with a key derived from it, so every replica must hold the same, stable value (a chart-generated one is not reproducible under helm template or GitOps renders).\n" -}}
{{- end -}}
{{- end -}}
{{- if and (eq $mode "host") (not .Values.admin.site.host) (or (eq (include "openctem.gatewayMode" .) "caddy") .Values.console.ingress.enabled) -}}
{{- fail "\n\nadmin.site.mode=host needs admin.site.host: the console's own DNS name (for example admin.example.com).\n" -}}
{{- end -}}
{{- end }}

{{/* The console allow-list, space-separated. */}}
{{- define "openctem.adminAllowedCidrs" -}}
{{- join " " .Values.admin.allowedCidrs -}}
{{- end }}

{{/* The gateway mode, validated. Empty string when the gateway is off. */}}
{{- define "openctem.gatewayMode" -}}
{{- $mode := toString (.Values.gateway.mode | default "none") -}}
{{- if not (has $mode (list "none" "ingress" "httpRoute" "caddy")) -}}
{{- fail (printf "\n\ngateway.mode=%q is not supported. Use one of: none, ingress, httpRoute, caddy.\n" $mode) -}}
{{- end -}}
{{- if ne $mode "none" -}}{{ $mode }}{{- end -}}
{{- end }}

{{/* The Caddy TLS mode, validated (caddy mode only). */}}
{{- define "openctem.gatewayCaddyTlsMode" -}}
{{- $tls := .Values.gateway.caddy.tls -}}
{{- $m := toString ($tls.mode | default "") -}}
{{- if not (has $m (list "internal" "acme" "files" "http")) -}}
{{- fail (printf "\n\ngateway.caddy.tls.mode=%q is not supported. Use one of: internal, acme, files, http.\n" $m) -}}
{{- end -}}
{{ $m }}
{{- end }}

{{/* Comma-separated SERVER_TRUSTED_PROXIES (list or string value). */}}
{{- define "openctem.gatewayTrustedProxies" -}}
{{- $v := .Values.gateway.trustedProxies -}}
{{- if kindIs "slice" $v -}}
{{- join "," $v -}}
{{- else -}}
{{- toString ($v | default "") | replace " " "" -}}
{{- end -}}
{{- end }}

{{/* The public origin. */}}
{{- define "openctem.gatewayPublicUrl" -}}
{{- if .Values.gateway.publicUrl -}}
{{- .Values.gateway.publicUrl | trimSuffix "/" -}}
{{- else if .Values.gateway.host -}}
{{- printf "https://%s" .Values.gateway.host -}}
{{- end -}}
{{- end }}

{{/*
Fail the render on a gateway configuration that cannot work. Called from the
API Deployment, which every render includes.
*/}}
{{- define "openctem.gatewayValidate" -}}
{{- $mode := include "openctem.gatewayMode" . -}}
{{- if $mode -}}
{{- $caddyHttp := false -}}
{{- if eq $mode "caddy" -}}
{{- $tlsMode := include "openctem.gatewayCaddyTlsMode" . -}}
{{- $tls := .Values.gateway.caddy.tls -}}
{{- $caddyHttp = eq $tlsMode "http" -}}
{{- if and (eq $tlsMode "http") (not $tls.allowPlainHttp) -}}
{{- fail "\n\ngateway.caddy.tls.mode=http serves OpenCTEM WITHOUT encryption. Use it only behind a proxy that terminates TLS, and confirm with gateway.caddy.tls.allowPlainHttp=true.\n" -}}
{{- end -}}
{{- if and (eq $tlsMode "acme") (not $tls.acme.email) -}}
{{- fail "\n\ngateway.caddy.tls.mode=acme needs gateway.caddy.tls.acme.email (the ACME account contact).\n" -}}
{{- end -}}
{{- if and (eq $tlsMode "files") (not $tls.files.secretName) -}}
{{- fail "\n\ngateway.caddy.tls.mode=files needs gateway.caddy.tls.files.secretName (a kubernetes.io/tls Secret with tls.crt and tls.key).\n" -}}
{{- end -}}
{{- end -}}
{{- if and (not .Values.gateway.host) (not $caddyHttp) -}}
{{- fail (printf "\n\ngateway.mode=%s needs gateway.host: the public DNS name (or IP address) clients use.\n" $mode) -}}
{{- end -}}
{{- if and $caddyHttp (not .Values.gateway.host) (not .Values.gateway.publicUrl) -}}
{{- fail "\n\ngateway.caddy.tls.mode=http needs gateway.publicUrl (the https:// origin of the TLS proxy in front) or gateway.host.\n" -}}
{{- end -}}
{{- if not (include "openctem.gatewayTrustedProxies" .) -}}
{{- fail (printf "\n\ngateway.mode=%s needs gateway.trustedProxies: the CIDRs of the pods that connect to the API (the gateway or ingress controller, the UI and the console), usually the cluster's pod CIDR, e.g. [10.244.0.0/16] (kubeadm/flannel) or [10.42.0.0/16] (k3s). Find it with: kubectl cluster-info dump | grep -m1 -- --cluster-cidr\n" $mode) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Names set in api.extraEnv (they win over the gateway's settings). */}}
{{- define "openctem.apiExtraEnvNames" -}}
{{- $names := list -}}
{{- range $e := .Values.api.extraEnv -}}
{{- if and (kindIs "map" $e) $e.name -}}
{{- $names = append $names (toString $e.name) -}}
{{- end -}}
{{- end -}}
{{- toJson $names -}}
{{- end }}

{{/*
API environment for the gateway: who may assert the client IP, and the public
origin. SERVER_TRUSTED_PROXIES is also honoured without a gateway mode (e.g.
behind the per-component ingresses).
*/}}
{{- define "openctem.gatewayApiEnv" -}}
{{- include "openctem.gatewayValidate" . -}}
{{- $mode := include "openctem.gatewayMode" . -}}
{{- $have := include "openctem.apiExtraEnvNames" . | fromJsonArray -}}
{{- $out := list -}}
{{- $tp := include "openctem.gatewayTrustedProxies" . -}}
{{- if and $tp (not (has "SERVER_TRUSTED_PROXIES" $have)) -}}
{{- $out = append $out (dict "name" "SERVER_TRUSTED_PROXIES" "value" $tp) -}}
{{- end -}}
{{- if $mode -}}
{{- $url := include "openctem.gatewayPublicUrl" . -}}
{{- range $name := list "APP_URL" "CORS_ALLOWED_ORIGINS" "SMTP_BASE_URL" -}}
{{- if not (has $name $have) -}}
{{- $out = append $out (dict "name" $name "value" $url) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end }}
