{{/*
Helpers of the S3 chart.
*/}}

{{/* "rustfs" or "rgw" (validated). */}}
{{- define "s3.provider" -}}
{{- $p := .Values.s3.provider | default "rustfs" -}}
{{- if not (has $p (list "rustfs" "rgw")) -}}
{{- fail (printf "s3.provider must be rustfs or rgw (got %q)" $p) -}}
{{- end -}}
{{- $p -}}
{{- end -}}

{{/* Bucket name, validated against the S3 naming rules. */}}
{{- define "s3.bucket" -}}
{{- $b := .Values.s3.bucket | default "cm-mes" -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$" $b) -}}
{{- fail (printf "s3.bucket %q is not a valid bucket name (3-63 characters: lowercase letters, digits, dots and hyphens)" $b) -}}
{{- end -}}
{{- $b -}}
{{- end -}}

{{- define "s3.fullname" -}}
{{- include "common.fullname" (dict "ctx" . "component" "s3") -}}
{{- end -}}

{{- define "s3.headless" -}}
{{- include "common.fullname" (dict "ctx" . "component" "s3-headless") -}}
{{- end -}}

{{- define "s3.credentialsSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "s3-credentials") -}}
{{- end -}}

{{- define "s3.tlsSecret" -}}
{{- include "common.tls.secretName" (dict "ctx" . "component" "s3" "existingSecret" .Values.s3.rustfs.tls.existingSecret) -}}
{{- end -}}

{{/* In-cluster FQDN of the S3 API Service (the MES "Address"). */}}
{{- define "s3.address" -}}
{{- include "common.svcFqdn" (dict "ctx" . "name" (include "s3.fullname" .)) -}}
{{- end -}}

{{/* S3 endpoint URL used by the Job, the tests and printed for the admin. */}}
{{- define "s3.endpointUrl" -}}
{{- printf "https://%s:443" (include "s3.address" .) -}}
{{- end -}}

{{/* RustFS ports. */}}
{{- define "s3.apiPort" -}}9000{{- end -}}
{{- define "s3.consolePort" -}}9001{{- end -}}

{{/* Numeric UID/GID of the RustFS image (user "rustfs" in the Dockerfile). */}}
{{- define "s3.uid" -}}10001{{- end -}}

{{/*
Validates the RustFS erasure-coding layout and returns nothing.

  N  = replicas x volumesPerPod (one erasure set, so 4 <= N <= 16)
  p  = parity, 1 <= p <= N/2
  d  = N - p data shards;  read quorum = d;  write quorum = d (+1 if d == p)
  The loss of one pod removes volumesPerPod drives: N - volumesPerPod must still reach the
  write quorum (and therefore the read quorum), otherwise one node failure stops the service.
*/}}
{{- define "s3.rustfs.validate" -}}
{{- $r := int .Values.s3.rustfs.replicas -}}
{{- $v := int .Values.s3.rustfs.volumesPerPod -}}
{{- $p := int .Values.s3.rustfs.parity -}}
{{- $n := mul $r $v | int -}}
{{- if or (lt $r 1) (lt $v 1) -}}
{{- fail "s3.rustfs.replicas and s3.rustfs.volumesPerPod must be at least 1" -}}
{{- end -}}
{{- if lt $n 4 -}}
{{- fail (printf "RustFS needs at least 4 drives for erasure coding, but s3.rustfs.replicas x s3.rustfs.volumesPerPod = %d x %d = %d. Use for example 3 x 2." $r $v $n) -}}
{{- end -}}
{{- if gt $n 16 -}}
{{- fail (printf "s3.rustfs.replicas x s3.rustfs.volumesPerPod = %d drives; this chart supports one erasure set of at most 16 drives. Use larger volumes instead." $n) -}}
{{- end -}}
{{- if or (lt $p 1) (gt $p (div $n 2)) -}}
{{- fail (printf "s3.rustfs.parity must be between 1 and %d (half of the %d drives), got %d" (div $n 2) $n $p) -}}
{{- end -}}
{{- $d := sub $n $p | int -}}
{{- $wq := $d -}}
{{- if eq $d $p -}}{{- $wq = add $d 1 | int -}}{{- end -}}
{{- if lt (sub $n $v | int) $wq -}}
{{- fail (printf "With %d pods x %d volumes and parity %d, losing one pod leaves %d drives, below the write quorum of %d: one node failure would stop the S3 service. Use more pods (e.g. replicas=3, volumesPerPod=2, parity=2) or another parity." $r $v $p (sub $n $v | int) $wq) -}}
{{- end -}}
{{- end -}}

{{/*
RUSTFS_VOLUMES: one ellipsis expression for all the pods and drives, e.g.
https://cmmes-s3-{0...2}.cmmes-s3-headless.ns.svc.cluster.local:9000/mnt/data{0...1}
*/}}
{{- define "s3.rustfs.volumes" -}}
{{- $r := int .Values.s3.rustfs.replicas -}}
{{- $v := int .Values.s3.rustfs.volumesPerPod -}}
{{- $hosts := printf "%s-{0...%d}.%s.%s.svc.%s" (include "s3.fullname" .) (sub $r 1) (include "s3.headless" .) .Release.Namespace (include "common.clusterDomain" .) -}}
{{- if eq $r 1 -}}
{{- $hosts = printf "%s-0.%s.%s.svc.%s" (include "s3.fullname" .) (include "s3.headless" .) .Release.Namespace (include "common.clusterDomain" .) -}}
{{- end -}}
{{- $drives := printf "/mnt/data{0...%d}" (sub $v 1) -}}
{{- if eq $v 1 -}}{{- $drives = "/mnt/data0" -}}{{- end -}}
{{- printf "https://%s:%s%s" $hosts (include "s3.apiPort" .) $drives -}}
{{- end -}}

{{/* Generated credentials (stable across upgrades, identical in every template). */}}
{{- define "s3.rootAccessKey" -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "s3.credentialsSecret" .) "key" "root-access-key" "value" .Values.s3.rustfs.auth.rootUser "length" 20) -}}
{{- end -}}
{{- define "s3.rootSecretKey" -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "s3.credentialsSecret" .) "key" "root-secret-key" "value" .Values.s3.rustfs.auth.rootPassword "length" 40) -}}
{{- end -}}
{{- define "s3.mesAccessKey" -}}
{{- if .Values.s3.rustfs.mesUser.enabled -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "s3.credentialsSecret" .) "key" "mes-access-key" "value" .Values.s3.rustfs.mesUser.accessKey "length" 20) -}}
{{- else -}}
{{- include "s3.rootAccessKey" . -}}
{{- end -}}
{{- end -}}
{{- define "s3.mesSecretKey" -}}
{{- if .Values.s3.rustfs.mesUser.enabled -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "s3.credentialsSecret" .) "key" "mes-secret-key" "value" .Values.s3.rustfs.mesUser.secretKey "length" 40) -}}
{{- else -}}
{{- include "s3.rootSecretKey" . -}}
{{- end -}}
{{- end -}}

{{/* Name of the canned policy granted to the MES user. */}}
{{- define "s3.mesPolicyName" -}}
{{- printf "%s-mes-bucket" (include "common.prefix" .) -}}
{{- end -}}

{{/* true when RustFS exports telemetry to the local collector. */}}
{{- define "s3.otlpEnabled" -}}
{{- if and .Values.observability .Values.observability.otlpEndpoint -}}true{{- end -}}
{{- end -}}

{{/* Local OpenTelemetry collector (charts/otel), OTLP/HTTP. */}}
{{- define "s3.otlpCollector" -}}
{{- printf "http://%s:4318" (include "common.svcFqdn" (dict "ctx" . "name" (include "common.fullname" (dict "ctx" . "component" "otel")))) -}}
{{- end -}}

{{/*
Environment shared by the aws-cli containers (Job and test): TLS CA, region, and the
checksum mode that every S3-compatible server accepts.
*/}}
{{- define "s3.awsCliEnv" -}}
- name: HOME
  value: /tmp/home
- name: AWS_CA_BUNDLE
  value: /etc/s3-tls/ca.crt
- name: AWS_DEFAULT_REGION
  value: {{ .Values.s3.rustfs.region | default "us-east-1" | quote }}
- name: AWS_ENDPOINT_URL
  value: {{ include "s3.endpointUrl" . | quote }}
- name: AWS_REQUEST_CHECKSUM_CALCULATION
  value: when_required
- name: AWS_RESPONSE_CHECKSUM_VALIDATION
  value: when_required
- name: AWS_PAGER
  value: ""
- name: BUCKET
  value: {{ include "s3.bucket" . | quote }}
{{- end -}}

{{/* Volumes shared by the Job and test pods: writable HOME/tmp and the CA. */}}
{{- define "s3.clientVolumes" -}}
- name: tmp
  emptyDir: {}
- name: tls
  secret:
    secretName: {{ include "s3.tlsSecret" . }}
    items:
      - key: ca.crt
        path: ca.crt
{{- end -}}

{{- define "s3.clientVolumeMounts" -}}
- name: tmp
  mountPath: /tmp
- name: tls
  mountPath: /etc/s3-tls
  readOnly: true
{{- end -}}
