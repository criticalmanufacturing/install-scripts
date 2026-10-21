{{- define "saas-connector.labels" -}}
app.kubernetes.io/name: saas-connector
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end -}}

{{- define "saas-connector.cloudHost" -}}
{{- $host := "" -}}
{{- $yaml := .Values.linkYaml | replace "\r\n" "\n" | trimPrefix "\ufeff" -}}
{{- range $document := regexSplit "(?m)^---[ \\t]*(#.*)?$" $yaml -1 -}}
  {{- $resource := fromYaml $document -}}
  {{- if and (eq ($resource.kind | default "") "Link") (not $host) -}}
    {{- $endpoints := dig "spec" "endpoints" (list) $resource -}}
    {{- if $endpoints -}}
      {{- $host = (first $endpoints).host | default "" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- default $host .Values.cloudHost | required "linkYaml must include a Link endpoint hostname, or set cloudHost explicitly" -}}
{{- end -}}
