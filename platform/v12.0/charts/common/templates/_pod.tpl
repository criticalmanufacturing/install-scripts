{{/*
Pod-level helpers: images, pull secrets, security contexts and scheduling.
*/}}

{{/*
Full image reference, honouring global.imageRegistry for private registries.
image: { repository: "apache/kafka", tag: "4.3.1", pullPolicy: IfNotPresent }
Usage: include "common.image" (dict "ctx" $ "image" .Values.kafka.image)
*/}}
{{- define "common.image" -}}
{{- $registry := .ctx.Values.global.imageRegistry | default "" | trimSuffix "/" -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository (toString .image.tag) -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (toString .image.tag) -}}
{{- end -}}
{{- end -}}

{{/* Usage: include "common.imagePullSecrets" $ */}}
{{- define "common.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ if kindIs "map" . }}{{ .name }}{{ else }}{{ . }}{{ end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Returns "true" when rendering for OpenShift.
global.platform: auto (default) | openshift | kubernetes
In "auto" mode OpenShift is detected through the security.openshift.io API group.
*/}}
{{- define "common.isOpenShift" -}}
{{- $platform := .Values.global.platform | default "auto" -}}
{{- if eq $platform "openshift" -}}
true
{{- else if and (eq $platform "auto") (.Capabilities.APIVersions.Has "security.openshift.io/v1") -}}
true
{{- end -}}
{{- end -}}

{{/*
Pod security context. On OpenShift the UID/GID/fsGroup are assigned by the
restricted-v2 SCC, so they are omitted. Everywhere else the image's UID is used.
Usage: include "common.podSecurityContext" (dict "ctx" $ "uid" 1000 "gid" 1000)
*/}}
{{- define "common.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  {{- if not (include "common.isOpenShift" .ctx) }}
  runAsUser: {{ .uid }}
  runAsGroup: {{ .gid | default .uid }}
  fsGroup: {{ .gid | default .uid }}
  fsGroupChangePolicy: OnRootMismatch
  {{- end }}
{{- end -}}

{{/* Container security context (identical on every platform). */}}
{{- define "common.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{/*
Affinity. If the component defines its own affinity it is used as-is, otherwise
pods of the same component are spread one per node (global.podAntiAffinity:
hard (default) = required, soft = preferred).
Usage: include "common.affinity" (dict "ctx" $ "component" "kafka" "affinity" .Values.kafka.affinity)
*/}}
{{- define "common.affinity" -}}
{{- if .affinity }}
affinity:
  {{- toYaml .affinity | nindent 2 }}
{{- else }}
{{- $mode := .ctx.Values.global.podAntiAffinity | default "hard" }}
affinity:
  podAntiAffinity:
    {{- if eq $mode "hard" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "common.selectorLabels" (dict "ctx" .ctx "component" .component) | nindent 12 }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              {{- include "common.selectorLabels" (dict "ctx" .ctx "component" .component) | nindent 14 }}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
Spread pods evenly across nodes. Used when a component has more pods than the
minimum node count (e.g. RustFS), together with soft anti-affinity.
Usage: include "common.topologySpread" (dict "ctx" $ "component" "s3")
*/}}
{{- define "common.topologySpread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        {{- include "common.selectorLabels" (dict "ctx" .ctx "component" .component) | nindent 8 }}
{{- end -}}

{{/*
nodeSelector and tolerations. Component-level values win over global ones.
Usage: include "common.scheduling" (dict "ctx" $ "nodeSelector" .Values.kafka.nodeSelector "tolerations" .Values.kafka.tolerations)
*/}}
{{- define "common.scheduling" -}}
{{- $nodeSelector := .nodeSelector | default .ctx.Values.global.nodeSelector -}}
{{- $tolerations := .tolerations | default .ctx.Values.global.tolerations -}}
{{- with $nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
storageClassName for a volumeClaimTemplate. Component value wins over global.
Empty = cluster default StorageClass.
Usage: include "common.storageClass" (dict "ctx" $ "storageClass" .Values.kafka.storage.storageClass)
*/}}
{{- define "common.storageClass" -}}
{{- $sc := .storageClass | default .ctx.Values.global.storageClass -}}
{{- if $sc }}
storageClassName: {{ $sc | quote }}
{{- end }}
{{- end -}}

{{/*
PodDisruptionBudget allowing one pod of the component to be down at a time.
Usage: include "common.pdb" (dict "ctx" $ "component" "kafka" "maxUnavailable" 1)
*/}}
{{- define "common.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "common.fullname" (dict "ctx" .ctx "component" .component) }}
  namespace: {{ .ctx.Release.Namespace }}
  labels:
    {{- include "common.labels" (dict "ctx" .ctx "component" .component) | nindent 4 }}
spec:
  maxUnavailable: {{ .maxUnavailable | default 1 }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" (dict "ctx" .ctx "component" .component) | nindent 6 }}
{{- end -}}
