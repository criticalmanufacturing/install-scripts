{{/*
Helpers of the S3 chart.
*/}}

{{/* Only standalone RustFS is provided by this chart. */}}
{{- define "s3.provider" -}}
{{- $p := .Values.s3.provider | default "rustfs" -}}
{{- if ne $p "rustfs" -}}
{{- fail "The MES 11.3 S3 chart deploys standalone RustFS; s3.provider must be rustfs. Use s3.enabled=false for external storage." -}}
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

{{/* S3 endpoint URL used by the setup Job and printed for the admin. */}}
{{- define "s3.endpointUrl" -}}
{{- printf "https://%s:443" (include "s3.address" .) -}}
{{- end -}}

{{/* RustFS ports. */}}
{{- define "s3.apiPort" -}}9000{{- end -}}
{{- define "s3.consolePort" -}}9001{{- end -}}

{{/* Numeric UID/GID of the RustFS image (user "rustfs" in the Dockerfile). */}}
{{- define "s3.uid" -}}10001{{- end -}}

{{/* Reject distributed settings instead of silently changing the on-disk layout. */}}
{{- define "s3.rustfs.validate" -}}
{{- if or (ne (int .Values.s3.rustfs.replicas) 1) (ne (int .Values.s3.rustfs.volumesPerPod) 1) -}}
{{- fail "The MES 11.3 S3 chart requires one RustFS server and one data volume (replicas=1, volumesPerPod=1). Migrate existing distributed data through S3 to a separate deployment." -}}
{{- end -}}
{{- if or (hasKey .Values.s3.rustfs "parity") (hasKey .Values.s3.rustfs "allowSharedDisks") (hasKey .Values.s3 "rgw") -}}
{{- fail "The MES 11.3 S3 chart does not accept erasure-coding, shared-disk or Ceph RGW settings." -}}
{{- end -}}
{{- end -}}

{{/* A single local path selects RustFS standalone mode. */}}
{{- define "s3.rustfs.volumes" -}}/mnt/data0{{- end -}}

{{/* Space-separated host:port of every RustFS pod (headless DNS), e.g. for per-pod checks. */}}
{{- define "s3.podHosts" -}}
{{- $hosts := list -}}
{{- range $i := until (int .Values.s3.rustfs.replicas) -}}
{{- $hosts = append $hosts (printf "%s-%d.%s.%s.svc.%s:%s" (include "s3.fullname" $) $i (include "s3.headless" $) $.Release.Namespace (include "common.clusterDomain" $) (include "s3.apiPort" $)) -}}
{{- end -}}
{{- join " " $hosts -}}
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

{{/*
Environment shared by the setup Job containers: TLS CA, region, and the
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

{{/* Volumes used by the setup Job: writable HOME/tmp and the CA. */}}
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
