{{/*
Naming and labels.

Every resource is named "<global.namePrefix>-<component>" so names are predictable
and independent of the Helm release name. Charts that are installed by install.sh
use the same value for the release name.
*/}}

{{/* The name prefix shared by all components. */}}
{{- define "common.prefix" -}}
{{- .Values.global.namePrefix | default "cmmes" | trunc 20 | trimSuffix "-" -}}
{{- end -}}

{{/*
Resource name for a component.
Usage: include "common.fullname" (dict "ctx" $ "component" "kafka")
*/}}
{{- define "common.fullname" -}}
{{- printf "%s-%s" (include "common.prefix" .ctx) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.clusterDomain" -}}
{{- .Values.global.clusterDomain | default "cluster.local" -}}
{{- end -}}

{{/*
Fully qualified in-cluster DNS name of a service.
Usage: include "common.svcFqdn" (dict "ctx" $ "name" "cmmes-kafka")
*/}}
{{- define "common.svcFqdn" -}}
{{- printf "%s.%s.svc.%s" .name .ctx.Release.Namespace (include "common.clusterDomain" .ctx) -}}
{{- end -}}

{{/*
Selector labels.
Usage: include "common.selectorLabels" (dict "ctx" $ "component" "kafka")
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/*
Standard labels.
Usage: include "common.labels" (dict "ctx" $ "component" "kafka")
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: cm-mes-dependencies
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
{{ include "common.selectorLabels" . }}
{{- end -}}

{{/*
Labels for pod templates. Unlike common.labels they carry no chart/app version, so
bumping the chart version alone does not restart every pod.
Usage: include "common.podLabels" (dict "ctx" $ "component" "kafka")
*/}}
{{- define "common.podLabels" -}}
app.kubernetes.io/part-of: cm-mes-dependencies
{{ include "common.selectorLabels" . }}
{{- end -}}
