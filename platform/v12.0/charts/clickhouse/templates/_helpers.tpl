{{/*
ClickHouse chart helpers.

Components (app.kubernetes.io/name): "clickhouse" (servers) and "keeper" (ClickHouse Keeper).
*/}}

{{/* UID/GID of the "clickhouse" user in both images (clickhouse-server and clickhouse-keeper). */}}
{{- define "clickhouse.uid" -}}101{{- end -}}

{{/* Fails with a clear message on invalid values. Included by every workload template. */}}
{{- define "clickhouse.validate" -}}
{{- $ch := .Values.clickhouse -}}
{{- $keeper := int $ch.keeper.replicas -}}
{{- if or (lt $keeper 1) (eq (mod $keeper 2) 0) -}}
{{- fail (printf "clickhouse.keeper.replicas must be an odd number (1, 3, 5, ...), got %d. Keeper needs a majority of its servers to work: 3 tolerates the loss of one server, 5 of two." $keeper) -}}
{{- end -}}
{{- if lt (int $ch.replicas) 1 -}}
{{- fail (printf "clickhouse.replicas must be at least 1 (2 or more for high availability), got %d" (int $ch.replicas)) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (toString $ch.auth.username)) -}}
{{- fail (printf "clickhouse.auth.username must contain only letters, digits and _ and must not start with a digit, got %q" (toString $ch.auth.username)) -}}
{{- end -}}
{{- if eq (toString $ch.auth.username) "default" -}}
{{- fail "clickhouse.auth.username must not be \"default\": the built-in default user is restricted to localhost" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (toString $ch.clusterName)) -}}
{{- fail (printf "clickhouse.clusterName must contain only letters, digits and _, got %q" (toString $ch.clusterName)) -}}
{{- end -}}
{{- end -}}

{{/* Escapes a string for use as XML text. */}}
{{- define "clickhouse.xml" -}}
{{- toString . | replace "&" "&amp;" | replace "<" "&lt;" | replace ">" "&gt;" -}}
{{- end -}}

{{/* Resource names. */}}
{{- define "clickhouse.fullname" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse") }}{{- end -}}
{{- define "clickhouse.headless" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-headless") }}{{- end -}}
{{- define "clickhouse.keeper.fullname" -}}{{ include "common.fullname" (dict "ctx" . "component" "keeper") }}{{- end -}}
{{- define "clickhouse.keeper.headless" -}}{{ include "common.fullname" (dict "ctx" . "component" "keeper-headless") }}{{- end -}}
{{- define "clickhouse.usersSecret" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-users") }}{{- end -}}
{{- define "clickhouse.configMap" -}}{{ include "common.fullname" (dict "ctx" . "component" "clickhouse-config") }}{{- end -}}
{{- define "clickhouse.keeper.configMap" -}}{{ include "common.fullname" (dict "ctx" . "component" "keeper-config") }}{{- end -}}
{{- define "clickhouse.tlsSecret" -}}{{ include "common.tls.secretName" (dict "ctx" . "component" "clickhouse" "existingSecret" .Values.clickhouse.tls.existingSecret) }}{{- end -}}

{{/* Per-pod DNS names. */}}
{{- define "clickhouse.podFqdn" -}}
{{- printf "%s-%d.%s" (include "clickhouse.fullname" .ctx) (int .index) (include "common.svcFqdn" (dict "ctx" .ctx "name" (include "clickhouse.headless" .ctx))) -}}
{{- end -}}
{{- define "clickhouse.keeper.podFqdn" -}}
{{- printf "%s-%d.%s" (include "clickhouse.keeper.fullname" .ctx) (int .index) (include "common.svcFqdn" (dict "ctx" .ctx "name" (include "clickhouse.keeper.headless" .ctx))) -}}
{{- end -}}

{{/*
DNS SANs of the certificate shared by ClickHouse and Keeper: short, <svc>.<ns>, <svc>.<ns>.svc
and FQDN names of every Service, wildcards for the headless Services, and localhost
(clickhouse-client inside a pod).
*/}}
{{- define "clickhouse.tls.dnsNames" -}}
{{- $ns := .Release.Namespace -}}
{{- $domain := include "common.clusterDomain" . -}}
{{- $names := list -}}
{{- range $svc := list (include "clickhouse.fullname" .) (include "clickhouse.headless" .) (include "clickhouse.keeper.headless" .) -}}
{{- $names = concat $names (list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- range $svc := list (include "clickhouse.headless" .) (include "clickhouse.keeper.headless" .) -}}
{{- $names = concat $names (list (printf "*.%s" $svc) (printf "*.%s.%s" $svc $ns) (printf "*.%s.%s.svc" $svc $ns) (printf "*.%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- $names = append $names "localhost" -}}
{{- toYaml $names -}}
{{- end -}}

{{/*
Generated secrets, all stored in the Secret "<prefix>-clickhouse-users" and stable across
upgrades (common.secretValue). Usage: include "clickhouse.secret" (dict "ctx" $ "key" "mes-password")
  mes-password           CM MES administration user
  interserver-password   authentication between replicas (part fetches, interserver HTTPS)
  cluster-secret         authentication of distributed queries inside the cluster
  keeper-password        Keeper client password (max. 16 characters)
  named-collections-seed seed of the AES key that encrypts named collections in Keeper
*/}}
{{- define "clickhouse.secret" -}}
{{- $ch := .ctx.Values.clickhouse -}}
{{- $explicit := dict "mes-password" $ch.auth.password -}}
{{- $length := dict "keeper-password" 16 -}}
{{- include "common.secretValue" (dict "ctx" .ctx "secret" (include "clickhouse.usersSecret" .ctx) "key" .key "value" (index $explicit .key | default "") "length" (index $length .key | default 32)) -}}
{{- end -}}

{{/* AES-128 key (32 hex characters) for named collections stored in Keeper. */}}
{{- define "clickhouse.namedCollectionsKey" -}}
{{- include "clickhouse.secret" (dict "ctx" . "key" "named-collections-seed") | sha256sum | trunc 32 -}}
{{- end -}}

{{/* Environment variables with the secrets, read by the configuration through from_env. */}}
{{- define "clickhouse.secretEnv" -}}
{{- $secret := include "clickhouse.usersSecret" . -}}
{{- range $env, $key := dict "CLICKHOUSE_INTERSERVER_PASSWORD" "interserver-password" "CLICKHOUSE_CLUSTER_SECRET" "cluster-secret" "CLICKHOUSE_KEEPER_PASSWORD" "keeper-password" "CLICKHOUSE_NAMED_COLLECTIONS_KEY" "named-collections-key" }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $key }}
{{- end }}
{{- end -}}

{{/* Probes of the ClickHouse server: /ping on the HTTPS port (kubelet does not verify the certificate). */}}
{{- define "clickhouse.probe" -}}
httpGet:
  path: /ping
  port: https
  scheme: HTTPS
{{- end -}}

{{/*
Shell snippet run before ClickHouse/Keeper start: the TLS Secret is mounted with
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

{{/*
Shell snippet run before ClickHouse starts: waits (up to 8 minutes, within the startup probe's
10) until one Keeper answers
/ready (it belongs to a quorum with a leader). ClickHouse stops at startup when Keeper is not
reachable (replicated access storage), so without this wait a server that starts before
Keeper (reinstall, whole-cluster restart) crash-loops, and "helm --wait" fails.
*/}}
{{- define "clickhouse.waitForKeeper" -}}
keeper_ready() {
  local h
  for h in {{ range $i := until (int .Values.clickhouse.keeper.replicas) }}{{ include "clickhouse.keeper.podFqdn" (dict "ctx" $ "index" $i) }} {{ end }}; do
    if timeout 3 bash -c 'exec 3<>/dev/tcp/$0/9182 && printf "GET /ready HTTP/1.0\r\nHost: $0\r\nUser-Agent: cmmes\r\n\r\n" >&3 && head -1 <&3 | grep -q " 200 "' "$h" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
i=0
while ! keeper_ready && [ "$SECONDS" -lt 480 ]; do
  if [ $(( i++ % 10 )) -eq 0 ]; then echo "Waiting for ClickHouse Keeper ({{ include "clickhouse.keeper.fullname" . }}) to form a quorum..."; fi
  sleep 3
done
{{- end -}}

{{/* Validated list of clickhouse.replicatedDatabases. */}}
{{- define "clickhouse.replicatedDatabases" -}}
{{- $dbs := .Values.clickhouse.replicatedDatabases | default list -}}
{{- range $dbs -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (toString .)) -}}
{{- fail (printf "clickhouse.replicatedDatabases: %q is not a valid name (letters, digits and _, not starting with a digit)" (toString .)) -}}
{{- end -}}
{{- if has (lower (toString .)) (list "system" "default" "information_schema") -}}
{{- fail (printf "clickhouse.replicatedDatabases: %q is a built-in database" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- $dbs | uniq | join " " -}}
{{- end -}}
