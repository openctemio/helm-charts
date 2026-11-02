{{/*
Feed relay (the platform makes no outbound feed requests: a platform-owned
shared sensor downloads the signed feed files and uploads them to the API).

sensor.feedRelay.origins are extra https origins (a mirror) on top of the
official ones. Each one must also be in the job signer's allowlist
(SIGNER_FEED_ORIGINS); the chart sets both from the same list. Values are
validated here: an origin is scheme + host (+ port) only, https, no comma.
*/}}

{{/* Validated origins as a comma-separated string ("" when none or relay off). */}}
{{- define "openctem.feedRelayOrigins" -}}
{{- $sensor := include "openctem.sensor" . | fromYaml -}}
{{- $fr := $sensor.feedRelay | default dict -}}
{{- $out := list -}}
{{- if (hasKey $fr "enabled" | ternary $fr.enabled true) -}}
{{- range $o := ($fr.origins | default list) -}}
{{- $o = toString $o -}}
{{- if not (regexMatch "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$" $o) -}}
{{- fail (printf "\n\nsensor.feedRelay.origins: %q is not an https origin. Use scheme and host only, for example https://mirror.example.com (no path, no comma, no http).\n" $o) -}}
{{- end -}}
{{- $out = append $out $o -}}
{{- end -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}

{{/* "true" when the sensor-token Job should store relay mode for new installs. */}}
{{- define "openctem.feedRelayNewInstall" -}}
{{- $sensor := include "openctem.sensor" . | fromYaml -}}
{{- $fr := $sensor.feedRelay | default dict -}}
{{- $top := .Values.feedRelay | default dict -}}
{{- if and (hasKey $top "newInstallRelay" | ternary $top.newInstallRelay true) (hasKey $fr "enabled" | ternary $fr.enabled true) }}true{{ end -}}
{{- end -}}
