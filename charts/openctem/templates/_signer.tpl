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
  image: "{{ .Values.api.image.repository }}:{{ .Values.api.image.tag | default .Chart.AppVersion }}"
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
{{- end -}}
