{{/*
API attachment storage (api.attachments): a volume at /app/data, or an
S3-compatible bucket. Validated here so a multi-replica API never renders with
storage only one pod can see.
*/}}

{{/* Most API pods that can run at once. */}}
{{- define "openctem.apiMaxReplicas" -}}
{{- if .Values.api.autoscaling.enabled -}}
{{- .Values.api.autoscaling.maxReplicas | int -}}
{{- else -}}
{{- .Values.api.replicaCount | int -}}
{{- end -}}
{{- end -}}

{{- define "openctem.apiAttachmentsStorageSecretName" -}}
{{- default (printf "%s-storage" (include "openctem.apiFullname" .)) .Values.api.attachments.s3.existingSecret -}}
{{- end -}}

{{/* "true" when the local volume is ReadWriteOnce-only (Recreate strategy). */}}
{{- define "openctem.apiAttachmentsRwoVolume" -}}
{{- $a := .Values.api.attachments -}}
{{- if and (eq $a.storage "local") $a.persistence.enabled (not (has "ReadWriteMany" $a.persistence.accessModes)) -}}
true
{{- end -}}
{{- end -}}

{{- define "openctem.apiAttachmentsValidate" -}}
{{- $a := .Values.api.attachments -}}
{{- $max := include "openctem.apiMaxReplicas" . | int -}}
{{- if eq $a.storage "s3" -}}
{{- if not (has $a.s3.provider (list "s3" "minio")) -}}
{{- fail (printf "\n\napi.attachments.s3.provider=%q is not supported. Use s3 or minio.\n" (toString $a.s3.provider)) -}}
{{- end -}}
{{- if not $a.s3.bucket -}}
{{- fail "\n\napi.attachments.storage=s3 needs api.attachments.s3.bucket.\n" -}}
{{- end -}}
{{- if and (not $a.s3.existingSecret) (or (not $a.s3.accessKey) (not $a.s3.secretKey)) -}}
{{- fail "\n\napi.attachments.storage=s3 needs credentials: api.attachments.s3.existingSecret (keys api.attachments.s3.accessKeyKey / secretKeyKey), or api.attachments.s3.accessKey and secretKey.\n" -}}
{{- end -}}
{{- else if eq $a.storage "local" -}}
{{- if gt $max 1 -}}
{{- if not $a.persistence.enabled -}}
{{- fail (printf "\n\nThe API can run %d replicas, but api.attachments.persistence.enabled=false keeps attachments on each pod's own disk: every pod would see different files, and they are lost with the pod.\nUse api.attachments.storage=s3, or a ReadWriteMany volume (api.attachments.persistence.enabled=true, accessModes [ReadWriteMany]), or a single replica.\n" $max) -}}
{{- end -}}
{{- if not (has "ReadWriteMany" $a.persistence.accessModes) -}}
{{- fail (printf "\n\nThe API can run %d replicas, but the attachments volume is %v: only one pod (one node) can mount it, so the other replicas cannot start or would not see the files.\nUse api.attachments.storage=s3, or api.attachments.persistence.accessModes=[ReadWriteMany] with a storage class that supports it (NFS, CephFS, EFS, Azure Files, ...), or a single replica.\n" $max $a.persistence.accessModes) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- fail (printf "\n\napi.attachments.storage=%q is not supported. Use local or s3.\n" (toString $a.storage)) -}}
{{- end -}}
{{- end -}}

{{/* Environment for the API container. */}}
{{- define "openctem.apiAttachmentsEnv" -}}
{{- $a := .Values.api.attachments -}}
{{- if eq $a.storage "s3" -}}
- name: STORAGE_PROVIDER
  value: {{ $a.s3.provider | quote }}
- name: STORAGE_BUCKET
  value: {{ $a.s3.bucket | quote }}
{{- with $a.s3.region }}
- name: STORAGE_REGION
  value: {{ . | quote }}
{{- end }}
{{- with $a.s3.endpoint }}
- name: STORAGE_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: STORAGE_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.apiAttachmentsStorageSecretName" . }}
      key: {{ $a.s3.accessKeyKey }}
- name: STORAGE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "openctem.apiAttachmentsStorageSecretName" . }}
      key: {{ $a.s3.secretKeyKey }}
{{- else -}}
- name: STORAGE_PROVIDER
  value: "local"
- name: STORAGE_LOCAL_PATH
  value: "/app/data/attachments"
{{- end -}}
{{- end -}}

{{- define "openctem.apiAttachmentsVolumeMount" -}}
{{- if eq .Values.api.attachments.storage "local" -}}
- name: attachments
  mountPath: /app/data
{{- end -}}
{{- end -}}

{{- define "openctem.apiAttachmentsVolume" -}}
{{- $a := .Values.api.attachments -}}
{{- if eq $a.storage "local" -}}
- name: attachments
{{- if $a.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-attachments" (include "openctem.apiFullname" .)) $a.persistence.existingClaim }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}
{{- end -}}
