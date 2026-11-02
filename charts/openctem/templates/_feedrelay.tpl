{{/*
Feed relay (the platform makes no outbound feed requests: a platform-owned
shared sensor downloads the signed feed files and uploads them to the API).

sensor.feedRelay.origins are extra https origins (a mirror) on top of the
official ones. The signer matches a round's origins exactly, so an origin is
the full download prefix (for a mirror of the vulnerability feed: the mirror's
VULNFEED_BASE_URL plus /latest/download). Each one must also be in the job
signer's allowlist (SIGNER_FEED_ORIGINS); the chart renders the official
origins plus these, because a set SIGNER_FEED_ORIGINS replaces the signer's
built-in official list. Values are validated here: https, a host, an optional
port and path, no query, comma or "..".
*/}}

{{/* The official feed origins (the signer's built-in list). */}}
{{- define "openctem.feedRelayOfficialOrigins" -}}
https://github.com/openctemio/vulnfeed-bundles/releases/latest/download,https://github.com/openctemio/openctem/releases/latest/download
{{- end -}}

{{/* Validated origins as a comma-separated string ("" when none or relay off). */}}
{{- define "openctem.feedRelayOrigins" -}}
{{- $sensor := include "openctem.sensor" . | fromYaml -}}
{{- $fr := $sensor.feedRelay | default dict -}}
{{- $out := list -}}
{{- if (hasKey $fr "enabled" | ternary $fr.enabled true) -}}
{{- range $o := ($fr.origins | default list) -}}
{{- $o = toString $o -}}
{{- if or (not (regexMatch "^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$" $o)) (contains "/.." $o) (contains "/./" $o) -}}
{{- fail (printf "\n\nsensor.feedRelay.origins: %q is not an https origin. Use the full https download prefix, for example https://mirror.example.com/vulnfeed-bundles/releases/latest/download (no query, no comma, no http).\n" $o) -}}
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
