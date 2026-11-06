{{/*
ClickHouse chart helpers.

Single-server deployment for MES 11.3; no Keeper or replicated metadata.
*/}}

{{/* UID/GID of the clickhouse-server image. */}}
{{- define "clickhouse.uid" -}}101{{- end -}}

{{/* Fails with a clear message on invalid values. Included by every workload template. */}}
{{- define "clickhouse.validate" -}}
{{- $ch := .Values.clickhouse -}}
{{- if ne (int $ch.replicas) 1 -}}
{{- fail "MES 11.3 requires a single ClickHouse server: clickhouse.replicas must be 1" -}}
{{- end -}}
{{- range $key := list "keeper" "loadBalancer" "clusterName" "replication" "replicatedDatabases" -}}
{{- if hasKey $ch $key -}}
{{- fail (printf "clickhouse.%s is not supported by the MES 11.3 single-server chart" $key) -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (toString $ch.auth.username)) -}}
{{- fail (printf "clickhouse.auth.username must contain only letters, digits and _ and must not start with a digit, got %q" (toString $ch.auth.username)) -}}
{{- end -}}
{{- if eq (toString $ch.auth.username) "default" -}}
{{- fail "clickhouse.auth.username must not be \"default\": the built-in default user is restricted to localhost" -}}
{{- end -}}
{{- end -}}

{{/* Escapes a string for use as XML text. */}}
{{- define "clickhouse.xml" -}}
{{- toString . | replace "&" "&amp;" | replace "<" "&lt;" | replace ">" "&gt;" -}}
{{- end -}}

{{/* Resource names. */}}
{{- define "clickhouse.fullname" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse") }}{{- end -}}
{{- define "clickhouse.headless" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-headless") }}{{- end -}}


{{- define "clickhouse.usersSecret" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-users") }}{{- end -}}
{{- define "clickhouse.configMap" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-config") }}{{- end -}}



{{- define "clickhouse.tlsSecret" -}}{{ include "common.tls.secretName" (dict "ctx" . "component" "clickhouse" "existingSecret" .Values.clickhouse.tls.existingSecret) }}{{- end -}}

{{/* Per-pod DNS names. */}}
{{- define "clickhouse.podFqdn" -}}
{{- printf "%s-%d.%s" (include "clickhouse.fullname" .ctx) (int .index) (include "common.svcFqdn" (dict "ctx" .ctx "name" (include "clickhouse.headless" .ctx))) -}}
{{- end -}}


{{/* Service DNS names and the single server pod. */}}
{{- define "clickhouse.tls.dnsNames" -}}
{{- $ns := .Release.Namespace -}}
{{- $domain := include "common.clusterDomain" . -}}
{{- $names := list -}}
{{- range $svc := list (include "clickhouse.fullname" .) (include "clickhouse.headless" .) -}}
{{- $names = concat $names (list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- range $svc := list (include "clickhouse.headless" .) -}}
{{- $names = concat $names (list (printf "*.%s" $svc) (printf "*.%s.%s" $svc $ns) (printf "*.%s.%s.svc" $svc $ns) (printf "*.%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- $names = append $names "localhost" -}}
{{- toYaml $names -}}
{{- end -}}

{{/* Stable MES administrator password, retained across upgrades and reinstalls. */}}
{{- define "clickhouse.secret" -}}
{{- $ch := .ctx.Values.clickhouse -}}
{{- $explicit := dict "mes-password" $ch.auth.password -}}
{{- include "common.secretValue" (dict "ctx" .ctx "secret" (include "clickhouse.usersSecret" .ctx) "key" .key "value" (index $explicit .key | default "") "length" 32) -}}
{{- end -}}

{{/* Probes of the ClickHouse server: /ping on the HTTPS port (kubelet does not verify the certificate). */}}
{{- define "clickhouse.probe" -}}
httpGet:
  path: /ping
  port: https
  scheme: HTTPS
{{- end -}}

{{/*
Shell snippet run before ClickHouse starts: the TLS Secret is mounted with
optional: true so that a missing key gives this message instead of a mount error.
Usage: include "clickhouse.tlsCheck" (dict "ctx" $ "dir" "/etc/clickhouse-server/tls")
*/}}
{{- define "clickhouse.tlsCheck" -}}
for f in tls.crt tls.key ca.crt; do
  if [ ! -s "{{ .dir }}/$f" ]; then
    echo "FATAL: key '$f' is missing or empty in the TLS Secret {{ include "clickhouse.tlsSecret" .ctx }} (mounted at {{ .dir }})." >&2
    {{- if eq (include "common.tls.mode" .ctx) "certManager" }}
    echo "global.tls.mode=certManager: the issuer must be a CA-type issuer (CA, Vault, ...) that fills ca.crt, and the Certificate must be Ready (kubectl get certificate {{ include "clickhouse.tlsSecret" .ctx }})." >&2
    {{- else if eq (include "common.tls.mode" .ctx) "existing" }}
    echo "global.tls.mode=existing: the Secret must contain tls.crt, tls.key and ca.crt." >&2
    {{- end }}
    exit 1
  fi
done
{{- end -}}
