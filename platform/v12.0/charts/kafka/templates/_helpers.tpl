{{/*
Kafka chart helpers. Generic helpers live in charts/common.
*/}}

{{/* UID/GID of the "appuser" account of the apache/kafka image. */}}
{{- define "kafka.uid" -}}1000{{- end -}}

{{/* Ports (fixed: they are part of the MES connection contract). */}}
{{- define "kafka.port.client" -}}9093{{- end -}}
{{- define "kafka.port.internal" -}}9092{{- end -}}
{{- define "kafka.port.controller" -}}9094{{- end -}}

{{- define "kafka.fullname" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka") -}}
{{- end -}}

{{- define "kafka.headless" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-headless") -}}
{{- end -}}

{{- define "kafka.usersSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-users") -}}
{{- end -}}

{{- define "kafka.kraftSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-kraft") -}}
{{- end -}}

{{- define "kafka.configMap" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-config") -}}
{{- end -}}

{{- define "kafka.monitoringSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-monitoring") -}}
{{- end -}}

{{- define "kafka.stateConfigMap" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-state") -}}
{{- end -}}

{{/*
"true" once the KRaft quorum has been bootstrapped: the state ConfigMap already says so
(sticky), or the existing StatefulSet has at least one ready broker (a broker only
becomes ready after the quorum has formed). A server with an empty data volume then
never formats itself as an initial voter again (see start.sh).
*/}}
{{- define "kafka.quorumBootstrapped" -}}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace (include "kafka.stateConfigMap" .) -}}
{{- $sts := lookup "apps/v1" "StatefulSet" .Release.Namespace (include "kafka.fullname" .) -}}
{{- if and $cm $cm.data (eq (index $cm.data "quorum-bootstrapped" | default "") "true") -}}
true
{{- else if and $sts $sts.status (ge (int ($sts.status.readyReplicas | default 0)) 1) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "kafka.replicas" -}}
{{- $r := int .Values.kafka.replicas -}}
{{- if lt $r 1 -}}
{{- fail "kafka.replicas must be at least 1 (3 or more for production)" -}}
{{- end -}}
{{- $r -}}
{{- end -}}

{{/* sasl | mtls */}}
{{- define "kafka.authMethod" -}}
{{- $m := .Values.kafka.auth.method | default "sasl" -}}
{{- if not (has $m (list "sasl" "mtls")) -}}
{{- fail (printf "kafka.auth.method must be sasl or mtls (got %q)" $m) -}}
{{- end -}}
{{- $m -}}
{{- end -}}

{{/*
FQDN of one broker pod.
Usage: include "kafka.podFqdn" (dict "ctx" $ "index" 0)
*/}}
{{- define "kafka.podFqdn" -}}
{{- printf "%s-%d.%s" (include "kafka.fullname" .ctx) (int .index) (include "common.svcFqdn" (dict "ctx" .ctx "name" (include "kafka.headless" .ctx))) -}}
{{- end -}}

{{/*
Comma separated "host:port" list of every broker pod.
Usage: include "kafka.brokerList" (dict "ctx" $ "port" 9093)
*/}}
{{- define "kafka.brokerList" -}}
{{- $out := list -}}
{{- range $i := until (int (include "kafka.replicas" .ctx)) -}}
{{- $out = append $out (printf "%s:%v" (include "kafka.podFqdn" (dict "ctx" $.ctx "index" $i)) $.port) -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}

{{/*
DNS SANs of the broker certificate: both Services (short, <svc>.<ns>, <svc>.<ns>.svc, FQDN)
plus a wildcard for the per-pod names of the headless Service. Returned as JSON.
*/}}
{{- define "kafka.serverDnsNames" -}}
{{- $ns := .Release.Namespace -}}
{{- $domain := include "common.clusterDomain" . -}}
{{- $names := list -}}
{{- range $svc := list (include "kafka.fullname" .) (include "kafka.headless" .) -}}
{{- $names = concat $names (list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- $h := include "kafka.headless" . -}}
{{- $names = concat $names (list (printf "*.%s" $h) (printf "*.%s.%s" $h $ns) (printf "*.%s.%s.svc" $h $ns) (printf "*.%s.%s.svc.%s" $h $ns $domain)) -}}
{{- toJson $names -}}
{{- end -}}

{{/*
Stable password of a Kafka user (admin | mes | monitor), stored in "<prefix>-kafka-users".
Usage: include "kafka.password" (dict "ctx" $ "user" "mes")
*/}}
{{- define "kafka.password" -}}
{{- $explicit := index (.ctx.Values.kafka.auth.passwords | default dict) .user | default "" -}}
{{- include "common.secretValue" (dict "ctx" .ctx "secret" (include "kafka.usersSecret" .ctx) "key" (printf "%s-password" .user) "value" $explicit "length" 32) -}}
{{- end -}}

{{/*
A random KRaft UUID: 16 random bytes, base64url without padding (22 characters),
the format of "kafka-storage.sh random-uuid". A leading "-" is avoided so that the
value can never be mistaken for a command-line option.
*/}}
{{- define "kafka.randomUuid" -}}
{{- $u := randBytes 16 | replace "+" "-" | replace "/" "_" | trimSuffix "=" | trimSuffix "=" -}}
{{- if hasPrefix "-" $u -}}
{{- $u = printf "A%s" (substr 1 22 $u) -}}
{{- end -}}
{{- $u -}}
{{- end -}}

{{/*
KRaft identity, generated once and kept across upgrades in "<prefix>-kafka-kraft":
  cluster-id          - the KRaft cluster id (kafka.clusterId wins when set)
  initial-controllers - the --initial-controllers value used to format the first
                        brokers: "<id>@<pod fqdn>:9094:<directory id>,..."
Returns a JSON object.
*/}}
{{- define "kafka.kraft" -}}
{{- include "common.cache" . -}}
{{- $cache := index .Values "__cmCache" -}}
{{- if not (hasKey $cache "kafka/kraft") -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "kafka.kraftSecret" .) -}}
{{- $data := dict -}}
{{- if and $existing $existing.data -}}
{{- $data = $existing.data -}}
{{- end -}}
{{- $clusterId := "" -}}
{{- if .Values.kafka.clusterId -}}
{{- $clusterId = .Values.kafka.clusterId -}}
{{- else if hasKey $data "cluster-id" -}}
{{- $clusterId = index $data "cluster-id" | b64dec -}}
{{- else -}}
{{- $clusterId = include "kafka.randomUuid" . -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_][A-Za-z0-9_-]{21}$" $clusterId) -}}
{{- fail (printf "kafka.clusterId %q is not a valid KRaft cluster id (22 characters, base64url, as printed by kafka-storage.sh random-uuid)" $clusterId) -}}
{{- end -}}
{{- $initial := "" -}}
{{- if hasKey $data "initial-controllers" -}}
{{- $initial = index $data "initial-controllers" | b64dec -}}
{{- else -}}
{{- $voters := list -}}
{{- range $i := until (int (include "kafka.replicas" .)) -}}
{{- $voters = append $voters (printf "%d@%s:%s:%s" $i (include "kafka.podFqdn" (dict "ctx" $ "index" $i)) (include "kafka.port.controller" $) (include "kafka.randomUuid" $)) -}}
{{- end -}}
{{- $initial = join "," $voters -}}
{{- end -}}
{{- $_ := set $cache "kafka/kraft" (dict "clusterId" $clusterId "initialControllers" $initial) -}}
{{- end -}}
{{- index $cache "kafka/kraft" | toJson -}}
{{- end -}}

{{/*
Existing-mode key handling. Kafka only reads PKCS#8 PEM keys ("BEGIN PRIVATE KEY").
Returns "true" when the admin's Secret holds an RSA PKCS#1 key ("BEGIN RSA PRIVATE KEY")
that the chart must convert into a derived Secret "<name>-pkcs8"; fails with a clear
message for keys that cannot be converted (encrypted, EC SEC1). Returns "" when the
Secret cannot be read (helm template) or already holds a PKCS#8 key.
Usage: include "kafka.tls.needsPkcs8" (dict "ctx" $ "name" "my-secret")
*/}}
{{- define "kafka.tls.needsPkcs8" -}}
{{- $s := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- if and $s $s.data -}}
{{- range $k := list "tls.crt" "tls.key" "ca.crt" -}}
{{- if not (hasKey $s.data $k) -}}
{{- fail (printf "Secret %q must contain the keys tls.crt, tls.key and ca.crt (missing %s)" $.name $k) -}}
{{- end -}}
{{- end -}}
{{- $key := index $s.data "tls.key" | b64dec -}}
{{- if contains "ENCRYPTED" $key -}}
{{- fail (printf "Secret %q: tls.key is encrypted. Kafka needs an unencrypted PKCS#8 key: openssl pkcs8 -topk8 -nocrypt -in tls.key -out tls-pkcs8.key" .name) -}}
{{- else if contains "BEGIN RSA PRIVATE KEY" $key -}}
true
{{- else if not (contains "BEGIN PRIVATE KEY" $key) -}}
{{- fail (printf "Secret %q: tls.key must be a PEM PKCS#8 key (BEGIN PRIVATE KEY) or an RSA PKCS#1 key (BEGIN RSA PRIVATE KEY). Convert it with: openssl pkcs8 -topk8 -nocrypt -in tls.key -out tls-pkcs8.key" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Name of a TLS Secret to mount: in existing mode the derived PKCS#8 copy when the
admin's key had to be converted.
Usage: include "kafka.tls.mountName" (dict "ctx" $ "component" "kafka" "existingSecret" .Values.kafka.tls.existingSecret)
*/}}
{{- define "kafka.tls.mountName" -}}
{{- $name := include "common.tls.secretName" . -}}
{{- if and (eq (include "common.tls.mode" .ctx) "existing") (include "kafka.tls.needsPkcs8" (dict "ctx" .ctx "name" $name)) -}}
{{- printf "%s-pkcs8" $name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name -}}
{{- end -}}
{{- end -}}

{{/* Broker certificate Secret to mount. */}}
{{- define "kafka.tls.brokerSecret" -}}
{{- include "kafka.tls.mountName" (dict "ctx" . "component" "kafka" "existingSecret" .Values.kafka.tls.existingSecret) -}}
{{- end -}}

{{/*
Monitor client certificate Secret (CN=monitor, mTLS only). Mounted by charts/otel, which
computes the same name with common.tls.secretName (component "kafka-monitor"). It is
never converted: the collector (Go) reads PKCS#1 and PKCS#8 keys.
*/}}
{{- define "kafka.tls.monitorSecret" -}}
{{- include "common.tls.secretName" (dict "ctx" . "component" "kafka-monitor" "existingSecret" .Values.kafka.tls.existingMonitorSecret) -}}
{{- end -}}

{{/* MES client certificate Secret (mTLS only), CN=mes. */}}
{{- define "kafka.tls.clientSecret" -}}
{{- include "kafka.tls.mountName" (dict "ctx" . "component" "kafka-client" "existingSecret" .Values.kafka.tls.existingClientSecret) -}}
{{- end -}}

{{/*
Broker certificate manifest (auto: Secret, certManager: Certificate, existing: nothing),
rendered once and cached so that every template sees the same generated certificate.
*/}}
{{- define "kafka.tls.brokerCertificate" -}}
{{- include "common.cache" . -}}
{{- $cache := index .Values "__cmCache" -}}
{{- if not (hasKey $cache "kafka/brokerCert") -}}
{{- if eq (include "common.tls.mode" .) "auto" -}}
{{- include "common.tls.loadCA" (dict "ctx" . "component" "kafka") -}}
{{- end -}}
{{- $cert := include "common.tls.certificate" (dict "ctx" . "component" "kafka" "name" (include "common.tls.secretName" (dict "ctx" . "component" "kafka" "existingSecret" .Values.kafka.tls.existingSecret)) "cn" (include "kafka.fullname" .) "dnsNames" (include "kafka.serverDnsNames" . | fromJsonArray) "pkcs8" true) -}}
{{- $_ := set $cache "kafka/brokerCert" $cert -}}
{{- end -}}
{{- index $cache "kafka/brokerCert" -}}
{{- end -}}

{{/*
Monitor principal: "tls" (client certificate CN=monitor on the CLIENT listener) or
"sasl" (username/password). In mtls mode with tls.mode=existing and no
kafka.tls.existingMonitorSecret, the monitor principal falls back to SASL on the
INTERNAL listener (9092), which always accepts SASL_SSL.
*/}}
{{- define "kafka.monitor.auth" -}}
{{- if eq (include "kafka.authMethod" .) "sasl" -}}
sasl
{{- else if and (eq (include "common.tls.mode" .) "existing") (not .Values.kafka.tls.existingMonitorSecret) -}}
sasl
{{- else -}}
tls
{{- end -}}
{{- end -}}

{{/*
Bash function escaping a value for a double-quoted JAAS option (\ and ") and then for a
.properties file (\). Quoted replacement strings keep it independent of patsub_replacement.
*/}}
{{- define "kafka.script.escapeFns" -}}
# Escape a value for a double-quoted JAAS option, then for a .properties file.
jaas_escape() { local b=\\ q=\" v="$1"; v="${v//"$b"/"$b$b"}"; v="${v//"$q"/"$b$q"}"; v="${v//"$b"/"$b$b"}"; printf '%s' "$v"; }
{{- end -}}

{{/*
TLS volume. ca.crt is projected as optional so that a cert-manager issuer which does
not fill ca.crt gives a clear error from the scripts instead of a stuck mount.
Usage: include "kafka.tls.volume" (dict "name" "tls" "secret" $name "keys" (list "tls.crt" "tls.key"))
*/}}
{{- define "kafka.tls.volume" -}}
- name: {{ .name }}
  projected:
    sources:
      {{- if .keys }}
      - secret:
          name: {{ .secret }}
          items:
            {{- range .keys }}
            - key: {{ . }}
              path: {{ . }}
            {{- end }}
      {{- end }}
      - secret:
          name: {{ .secret }}
          optional: true
          items:
            - key: ca.crt
              path: ca.crt
{{- end -}}

{{/* Shell check that ca.crt was mounted. */}}
{{- define "kafka.script.checkCA" -}}
if [ ! -s /cm/tls/ca.crt ]; then
  echo "FATAL: the TLS Secret has no ca.crt. With global.tls.mode=certManager use a CA-type issuer (it fills ca.crt); with tls.mode=existing add ca.crt to the Secret." >&2
  exit 1
fi
{{- end -}}
