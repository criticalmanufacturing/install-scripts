{{/*
Secrets: stable generated passwords and the MES connection Secret.
*/}}

{{/*
Per-render cache shared by every template of a chart. Needed because random
values (passwords, certificates) must be identical in every template that uses them.
*/}}
{{- define "common.cache" -}}
{{- if not (hasKey .Values "__cmCache") -}}
{{- $_ := set .Values "__cmCache" (dict) -}}
{{- end -}}
{{- end -}}

{{/*
A secret value that is stable across upgrades. The first match wins:
  1. an explicit value (from values.yaml)
  2. the value already stored in the existing Secret (upgrade)
  3. a new random alphanumeric string
Usage: include "common.secretValue" (dict "ctx" $ "secret" "cmmes-kafka-users" "key" "mes-password" "value" .Values.kafka.auth.sasl.password "length" 24)
*/}}
{{- define "common.secretValue" -}}
{{- include "common.cache" .ctx -}}
{{- $cache := index .ctx.Values "__cmCache" -}}
{{- $cacheKey := printf "secret/%s/%s" .secret .key -}}
{{- if not (hasKey $cache $cacheKey) -}}
{{- $value := "" -}}
{{- if .value -}}
{{- $value = .value -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secret -}}
{{- if and $existing $existing.data (hasKey $existing.data .key) -}}
{{- $value = index $existing.data .key | b64dec -}}
{{- else -}}
{{- $value = randAlphaNum (int (.length | default 24)) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $cache $cacheKey $value -}}
{{- end -}}
{{- index $cache $cacheKey -}}
{{- end -}}

{{/*
MES connection Secret: "<prefix>-<component>-connection".

This is the contract with install.sh, which finds these Secrets through the label
cmf.criticalmanufacturing.com/connection=true and prints:
  - key "mes-installer.txt": the fields to type in the CM MES installer
  - key "ca.crt" of the Secret named in the annotation cmf.criticalmanufacturing.com/ca-secret
    (saved as <component>-ca.crt)
  - every key listed in the annotation cmf.criticalmanufacturing.com/files (comma separated),
    taken from the Secret named in cmf.criticalmanufacturing.com/files-secret (saved as <component>-<key>)

fields is a list of [label, value] pairs, printed in order.
Usage:
  include "common.connectionSecret" (dict "ctx" $ "component" "kafka" "title" "Kafka"
      "order" "10" "caSecret" "cmmes-kafka-tls"
      "fields" (list (list "Bootstrap Servers" "x:9093") (list "Kafka Username" "mes")))
*/}}
{{- define "common.connectionSecret" -}}
{{- $lines := list (printf "[%s]" .title) -}}
{{- range .fields -}}
{{- $lines = append $lines (printf "%-42s: %s" (index . 0) (toString (index . 1))) -}}
{{- end -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "common.fullname" (dict "ctx" .ctx "component" (printf "%s-connection" .component)) }}
  namespace: {{ .ctx.Release.Namespace }}
  labels:
    {{- include "common.labels" (dict "ctx" .ctx "component" .component) | nindent 4 }}
    cmf.criticalmanufacturing.com/connection: "true"
  annotations:
    cmf.criticalmanufacturing.com/component: {{ .component | quote }}
    cmf.criticalmanufacturing.com/order: {{ .order | default "50" | quote }}
    {{- with .caSecret }}
    cmf.criticalmanufacturing.com/ca-secret: {{ . | quote }}
    {{- end }}
    {{- with .files }}
    cmf.criticalmanufacturing.com/files: {{ join "," . | quote }}
    cmf.criticalmanufacturing.com/files-secret: {{ $.filesSecret | quote }}
    {{- end }}
type: Opaque
stringData:
  mes-installer.txt: |
    {{- range $lines }}
    {{ . }}
    {{- end }}
{{- end -}}
