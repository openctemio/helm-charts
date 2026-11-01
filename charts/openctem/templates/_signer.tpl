{{/*
Job signer (OpenCTEM docs/architecture/job-signing.md): every job the API
hands to a sensor is signed by openctem-signer with a key the API never holds.
The signer listens on a Unix socket only, so it runs as a sidecar container of
the API pod and the two share an emptyDir that holds the socket. Its key and
its state (sequence counter, signing log, scope ledger) are on volumes mounted
into the signer container alone.
*/}}

{{/* "true" when the signer sidecar is part of the API pod. */}}
{{- define "openctem.signerEnabled" -}}
{{- $s := .Values.api.signer | default dict -}}
{{- if $s.enabled }}true{{ end -}}
{{- end -}}

{{/* Names of the variables in api.extraEnv (as a JSON array). */}}
{{- define "openctem.signerExtraEnvNames" -}}
{{- $n := list -}}
{{- range $e := .Values.api.extraEnv -}}
{{- if kindIs "map" $e -}}{{- $n = append $n (toString ($e.name | default "")) -}}{{- end -}}
{{- end -}}
{{- toJson $n -}}
{{- end -}}

{{/* "true" when the key is generated on first start into a volume. */}}
{{- define "openctem.signerGenerateKey" -}}
{{- $s := .Values.api.signer -}}
{{- if and (not $s.key.existingSecret) (or $s.key.generate (ne (toString .Values.api.appEnv) "production")) }}true{{ end -}}
{{- end -}}

{{/* The signer's group: the API's, so the API can open the socket (0660). */}}
{{- define "openctem.signerRunAsGroup" -}}
{{- $s := .Values.api.signer -}}
{{- $psc := .Values.api.podSecurityContext | default dict -}}
{{- $s.runAsGroup | default $psc.runAsGroup | default 1000 -}}
{{- end -}}

{{/*
openctem.signerValidate: production refuses to render without the signer (the
API itself refuses to start without SIGNER_SOCKET), and the signer needs a
pod that nothing else can reach it through.
*/}}
{{- define "openctem.signerValidate" -}}
{{- $s := .Values.api.signer | default dict -}}
{{- $have := include "openctem.signerExtraEnvNames" . | fromJsonArray -}}
{{- $prod := eq (toString .Values.api.appEnv) "production" -}}
{{- if has "SIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS" $have -}}
{{- if $prod -}}
{{- fail "\n\nSIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS in api.extraEnv would let a production API hand sensors unsigned jobs. Remove it and run the signer (api.signer.enabled=true).\n" -}}
{{- end -}}
{{- end -}}
{{- if not $s.enabled -}}
{{- if $prod -}}
{{- fail "\n\napi.signer.enabled=false with api.appEnv=production: the API refuses to start without the job signer (SIGNER_SOCKET), and sensors would receive unsigned jobs. Enable the signer (the default).\n" -}}
{{- end -}}
{{- else -}}
{{- if has "SIGNER_SOCKET" $have -}}
{{- fail "\n\nSIGNER_SOCKET is set in api.extraEnv while api.signer.enabled=true: the chart sets it for its own signer sidecar. Remove one of them.\n" -}}
{{- end -}}
{{- if .Values.api.serviceAccount.automount -}}
{{- fail "\n\napi.signer.enabled=true needs api.serviceAccount.automount=false: the signer must not have a Kubernetes API token in its pod (a pod's containers share one).\n" -}}
{{- end -}}
{{- $max := include "openctem.apiMaxReplicas" . | int -}}
{{- if gt $max 1 -}}
{{- fail (printf "\n\napi.signer.enabled=true with %d API replicas: the signer keeps its sequence counter, signing log and scope ledger on one volume that a single signer may hold, so it runs only in a single-replica API pod. Set api.replicaCount=1 and api.autoscaling.enabled=false.\n" $max) -}}
{{- end -}}
{{- $psc := .Values.api.podSecurityContext | default dict -}}
{{- $sc := .Values.api.securityContext | default dict -}}
{{- $apiUid := int ($sc.runAsUser | default $psc.runAsUser | default 1000) -}}
{{- if eq (int $s.runAsUser) $apiUid -}}
{{- fail (printf "\n\napi.signer.runAsUser (%d) must differ from the API's user (%d): the signer's key and state must belong to a user the API is not.\n" (int $s.runAsUser) $apiUid) -}}
{{- end -}}
{{- if eq (int $s.runAsUser) 0 -}}
{{- fail "\n\napi.signer.runAsUser must not be 0.\n" -}}
{{- end -}}
{{- if and (not (include "openctem.signerGenerateKey" .)) (not $s.key.existingSecret) -}}
{{- fail "\n\napi.signer.enabled=true needs a signing key: api.signer.key.existingSecret (a Secret with the key under api.signer.key.secretKey, created with `openctem-signer keygen`), or api.signer.key.generate=true to create it on first start into a volume.\n" -}}
{{- end -}}
{{- if and $s.key.existingSecret $s.key.generate -}}
{{- fail "\n\napi.signer.key.existingSecret and api.signer.key.generate=true are alternatives: set one.\n" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* "true" when the signer's volumes are ReadWriteOnce (Recreate strategy). */}}
{{- define "openctem.signerRwoVolume" -}}
{{- if include "openctem.signerEnabled" . }}true{{ end -}}
{{- end -}}

{{/* The signer's environment. */}}
{{- define "openctem.signerEnv" -}}
- name: SIGNER_SOCKET
  value: /run/openctem-signer/signer.sock
- name: SIGNER_STATE_DIR
  value: /var/lib/openctem-signer/state
- name: SIGNER_KEY_FILE
  value: /var/lib/openctem-signer/keys/signer.pem
{{- if include "openctem.signerGenerateKey" . }}
- name: SIGNER_GENERATE_KEY
  value: "true"
{{- end }}
{{- if include "openctem.signerPublishForSensor" . }}
- name: SIGNER_PUBLISH_DIR
  value: /run/openctem-signer-pub
{{- end }}
{{- with .Values.api.signer.ledger.mode }}
- name: SIGNER_LEDGER
  value: {{ . | quote }}
{{- end }}
{{- if .Values.api.signer.keyset.existingSecret }}
- name: SIGNER_KEYSET_FILE
  value: /etc/openctem-signer/keyset/{{ .Values.api.signer.keyset.key }}
{{- end }}
{{- with .Values.api.signer.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Claim names. */}}
{{- define "openctem.signerStateClaim" -}}
{{- default (printf "%s-signer-state" (include "openctem.apiFullname" .)) .Values.api.signer.persistence.state.existingClaim -}}
{{- end -}}
{{- define "openctem.signerKeysClaim" -}}
{{- default (printf "%s-signer-keys" (include "openctem.apiFullname" .)) .Values.api.signer.key.persistence.existingClaim -}}
{{- end -}}

{{/* The signer sidecar's volumes (pod level). */}}
{{- define "openctem.signerVolumes" -}}
{{- $s := .Values.api.signer -}}
- name: signer-socket
  emptyDir: {}
- name: signer-state
  persistentVolumeClaim:
    claimName: {{ include "openctem.signerStateClaim" . }}
{{- if include "openctem.signerGenerateKey" . }}
- name: signer-keys
  persistentVolumeClaim:
    claimName: {{ include "openctem.signerKeysClaim" . }}
{{- else }}
# The key as the operator's Secret; only the init container reads it.
- name: signer-key-source
  secret:
    secretName: {{ $s.key.existingSecret }}
    # Read by the init container only. Files of a Secret belong to root, so the
    # signer's user needs the world bit; the copy it makes is 0400.
    defaultMode: 0444
    items:
      - key: {{ $s.key.secretKey }}
        path: signer.pem
- name: signer-keys
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
{{- end }}
{{- if $s.keyset.existingSecret }}
- name: signer-keyset
  secret:
    secretName: {{ $s.keyset.existingSecret }}
    defaultMode: 0444
{{- end }}
{{- end -}}

{{/* The signer's container security context, shared with its init container. */}}
{{- define "openctem.signerSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ int .Values.api.signer.runAsUser }}
runAsGroup: {{ include "openctem.signerRunAsGroup" . }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* The init container that installs a key from a Secret (key.existingSecret). */}}
{{- define "openctem.signerInitContainers" -}}
{{- if not (include "openctem.signerGenerateKey" .) }}
initContainers:
  - name: signer-key-install
    image: "{{ .Values.api.signer.keyInstaller.image.repository }}:{{ .Values.api.signer.keyInstaller.image.tag }}"
    imagePullPolicy: {{ .Values.api.signer.keyInstaller.image.pullPolicy }}
    command: ["/bin/sh", "-c"]
    args:
      - cp /key-source/signer.pem /keys/signer.pem && chmod 0400 /keys/signer.pem
    securityContext:
      {{- include "openctem.signerSecurityContext" . | nindent 6 }}
    resources:
      limits:
        memory: 16Mi
    volumeMounts:
      - name: signer-key-source
        mountPath: /key-source
        readOnly: true
      - name: signer-keys
        mountPath: /keys
{{- end }}
{{- end -}}

{{/* The signer container. */}}
{{- define "openctem.signerContainer" -}}
{{- $s := .Values.api.signer -}}
- name: signer
  image: {{ include "openctem.image" (dict "image" .Values.api.image "root" . "defaultTag" .Chart.AppVersion) | quote }}
  imagePullPolicy: {{ .Values.api.image.pullPolicy }}
  command: ["/app/openctem-signer"]
  args: ["serve"]
  securityContext:
    {{- include "openctem.signerSecurityContext" . | nindent 4 }}
  env:
    {{- include "openctem.signerEnv" . | nindent 4 }}
  startupProbe:
    exec:
      command: ["/app/openctem-signer", "healthcheck"]
    periodSeconds: 2
    failureThreshold: 30
  livenessProbe:
    exec:
      command: ["/app/openctem-signer", "healthcheck"]
    periodSeconds: 10
    timeoutSeconds: 3
  readinessProbe:
    exec:
      command: ["/app/openctem-signer", "healthcheck"]
    periodSeconds: 10
    timeoutSeconds: 3
  {{- with $s.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: signer-socket
      mountPath: /run/openctem-signer
    - name: signer-state
      mountPath: /var/lib/openctem-signer/state
    - name: signer-keys
      mountPath: /var/lib/openctem-signer/keys
    {{- if $s.keyset.existingSecret }}
    - name: signer-keyset
      mountPath: /etc/openctem-signer/keyset
      readOnly: true
    {{- end }}
    {{- if include "openctem.signerPublishForSensor" . }}
    - name: signer-pub
      mountPath: /run/openctem-signer-pub
    {{- end }}
{{- end -}}

{{/*
"true" when the sensor pins this chart's own signer key (sensor.jobSigning
.fromSigner, no root or keys given): the signer publishes its public key to
a volume only it writes, and the exporter container copies it into the
<api>-signer-pub ConfigMap the sensor mounts.
*/}}
{{- define "openctem.signerPublishForSensor" -}}
{{- $sensor := include "openctem.sensor" . | fromYaml -}}
{{- $js := $sensor.jobSigning | default dict -}}
{{- if and $sensor.enabled (include "openctem.signerEnabled" .) $js.fromSigner (not $js.root) (not $js.keys) }}true{{ end -}}
{{- end -}}

{{/* The ConfigMap the exporter writes the signer's public key into. */}}
{{- define "openctem.signerPubConfigMap" -}}
{{- printf "%s-signer-pub" (include "openctem.apiFullname" .) -}}
{{- end -}}

{{/*
The exporter container (API pod): copies signer.pub from the signer's
publish volume into the <api>-signer-pub ConfigMap. It alone mounts a
Kubernetes token (a projected volume; the pod keeps
automountServiceAccountToken false), whose Role allows only get and patch of
that one ConfigMap. Shell and curl only; the key is checked to be 44
base64 characters before it is sent.
*/}}
{{- define "openctem.signerPubExporterContainer" -}}
{{- $sensor := include "openctem.sensor" . | fromYaml -}}
{{- $ex := ($sensor.jobSigning | default dict).exporter | default dict -}}
- name: signer-pub-exporter
  image: {{ $ex.image | quote }}
  imagePullPolicy: IfNotPresent
  command: ["/bin/sh", "-c"]
  args:
    - |
      set -u
      f=/run/openctem-signer-pub/signer.pub
      t=/var/run/secrets/openctem-exporter
      url="https://kubernetes.default.svc/api/v1/namespaces/$(cat "$t/namespace")/configmaps/$CONFIGMAP"
      last=""
      logged=""
      n=0
      while true; do
        # Published again every 10 minutes, so an emptied ConfigMap is refilled.
        n=$((n + 1)); if [ "$n" -ge 30 ]; then n=0; last=""; fi
        if [ -f "$f" ]; then
          k="$(tr -d '\n' < "$f")"
          case "$k" in
            *[!A-Za-z0-9+/=]*) echo "signer.pub is not a base64 key; not published" >&2 ;;
            *)
              if [ "${#k}" -ne 44 ]; then
                echo "signer.pub is not a 32-byte key; not published" >&2
              elif [ "$k" != "$last" ]; then
                if curl -fsS -o /dev/null --max-time 20 --cacert "$t/ca.crt" \
                  -H "Authorization: Bearer $(cat "$t/token")" \
                  -H "Content-Type: application/merge-patch+json" \
                  -X PATCH --data "{\"data\":{\"signer.pub\":\"$k\"}}" "$url"; then
                  if [ "$k" != "$logged" ]; then
                    echo "signer public key published to ConfigMap $CONFIGMAP"
                    logged="$k"
                  fi
                  last="$k"
                fi
              fi
              ;;
          esac
        fi
        sleep 20
      done
  env:
    - name: CONFIGMAP
      value: {{ include "openctem.signerPubConfigMap" . | quote }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    privileged: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  {{- with $ex.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: signer-pub
      mountPath: /run/openctem-signer-pub
      readOnly: true
    - name: signer-pub-exporter-token
      mountPath: /var/run/secrets/openctem-exporter
      readOnly: true
{{- end -}}

{{/* The publish volume and the exporter's token (pod level). */}}
{{- define "openctem.signerPubVolumes" -}}
# The signer's public key: written by the signer only, read by the exporter.
- name: signer-pub
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
# A short-lived token of the API's service account, mounted into the
# exporter container only.
- name: signer-pub-exporter-token
  projected:
    defaultMode: 0444
    sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
      - downwardAPI:
          items:
            - path: namespace
              fieldRef:
                fieldPath: metadata.namespace
{{- end -}}
