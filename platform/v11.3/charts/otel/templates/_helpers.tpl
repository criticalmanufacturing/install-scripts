{{/*
Helpers for the OpenTelemetry collector chart.
*/}}

{{- define "otel.fullname" -}}
{{- include "common.fullname" (dict "ctx" . "component" "otel") -}}
{{- end -}}

{{/* Fails early when there is nowhere to send the metrics. */}}
{{- define "otel.endpoint" -}}
{{- $endpoint := .Values.observability.otlpEndpoint | default "" | trim -}}
{{- if not $endpoint -}}
{{- fail "observability.otlpEndpoint is empty: the otel chart needs an OTLP/HTTP endpoint to send metrics to (e.g. https://otlp.example.com:4318). Leave it empty only when you do not install this chart." -}}
{{- end -}}
{{- if not (regexMatch "^https?://[^[:space:]]+$" $endpoint) -}}
{{- fail (printf "observability.otlpEndpoint must start with http:// or https:// (got %q)" $endpoint) -}}
{{- end -}}
{{- $endpoint -}}
{{- end -}}

{{/* "true" when Kafka metrics are collected. */}}
{{- define "otel.kafka" -}}
{{- if and .Values.kafka (ne (toString (dig "enabled" true .Values.kafka)) "false") -}}true{{- end -}}
{{- end -}}

{{/* "true" when ClickHouse metrics are scraped. */}}
{{- define "otel.clickhouse" -}}
{{- if and .Values.clickhouse (ne (toString (dig "enabled" true .Values.clickhouse)) "false") -}}true{{- end -}}
{{- end -}}

{{/* Kafka 3.8 uses the dedicated read-only account on the SASL_SSL listener. */}}
{{- define "otel.kafkaAuth" -}}sasl{{- end -}}

{{- define "otel.kafkaSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "kafka-monitoring") -}}
{{- end -}}

{{/* Kafka TLS Secret holding the CA (ca.crt) that signed the broker certificates. */}}
{{- define "otel.kafkaCaSecret" -}}
{{- include "common.tls.secretName" (dict "ctx" . "component" "kafka" "existingSecret" (dig "tls" "existingSecret" "" .Values.kafka)) -}}
{{- end -}}

{{/* Checksum of the Kafka TLS material, so that a changed CA or certificate restarts the collector on upgrade. */}}
{{- define "otel.kafkaTlsChecksum" -}}
{{- $sum := "" -}}
{{- $names := list (include "otel.kafkaCaSecret" .) -}}
{{- range $names -}}
{{- $s := lookup "v1" "Secret" $.Release.Namespace . -}}
{{- if and $s $s.data -}}{{- $sum = printf "%s%s%s" $sum (index $s.data "ca.crt" | default "") (index $s.data "tls.crt" | default "") -}}{{- end -}}
{{- end -}}
{{- $sum | sha256sum -}}
{{- end -}}

{{- define "otel.headersSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "otel-headers") -}}
{{- end -}}

{{- define "otel.caConfigMap" -}}
{{- include "common.fullname" (dict "ctx" . "component" "otel-ca") -}}
{{- end -}}

{{/* Environment variable name holding the value of the i-th exporter header. */}}
{{- define "otel.headerEnv" -}}
{{- printf "OTEL_EXPORTER_HEADER_%d" (int .) -}}
{{- end -}}

{{/*
Resource processor attributes for one pipeline.
Usage: include "otel.resourceAttributes" (dict "ctx" $ "component" "kafka" "action" "upsert")
*/}}
{{- define "otel.resourceAttributes" -}}
attributes:
  - key: service.namespace
    value: {{ .ctx.Release.Namespace | toJson }}
    action: upsert
  {{- range $k, $v := .ctx.Values.observability.resourceAttributes }}
  - key: {{ $k | toJson }}
    value: {{ toString $v | toJson }}
    action: upsert
  {{- end }}
  {{- if .component }}
  - key: cm.component
    value: {{ .component | toJson }}
    action: {{ .action | default "upsert" }}
  {{- end }}
{{- end -}}

{{/* Static scrape targets "<prefix>-<name>-<i>.<prefix>-<name>-headless.<ns>.svc.<domain>:9363". */}}
{{- define "otel.targets" -}}
{{- $name := include "common.fullname" (dict "ctx" .ctx "component" .component) -}}
{{- $headless := printf "%s-headless" $name -}}
{{- $targets := list -}}
{{- range $i := until (int .replicas) -}}
{{- $targets = append $targets (printf "%s-%d.%s:9363" $name $i (include "common.svcFqdn" (dict "ctx" $.ctx "name" $headless))) -}}
{{- end -}}
{{- toJson $targets -}}
{{- end -}}

{{/* The collector configuration (config.yaml). */}}
{{- define "otel.config" -}}
{{- $obs := .Values.observability -}}
{{- $endpoint := include "otel.endpoint" . -}}
{{- $kafka := include "otel.kafka" . -}}
{{- $clickhouse := include "otel.clickhouse" . -}}
{{- $rabbitmq := ne (toString (dig "enabled" true .Values.rabbitmq)) "false" -}}
{{- $interval := $obs.scrapeInterval | default "30s" -}}
{{- $signals := $obs.otlpSignals | default dict -}}
{{- $rustfs := false -}}
{{- if and .Values.s3 (ne (toString (dig "enabled" true .Values.s3)) "false") (eq (toString (dig "provider" "rustfs" .Values.s3)) "rustfs") -}}
{{- $rustfs = true -}}
{{- end -}}
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  {{- if $clickhouse }}
  prometheus/clickhouse:
    config:
      scrape_configs:
        - job_name: clickhouse
          scrape_interval: {{ $interval }}
          metrics_path: /metrics
          scheme: http
          static_configs:
            - targets: {{ include "otel.targets" (dict "ctx" . "component" "clickhouse" "replicas" (.Values.clickhouse.replicas | default 1)) }}
  {{- end }}
  {{- if $rabbitmq }}
  prometheus/rabbitmq:
    config:
      scrape_configs:
        - job_name: rabbitmq
          scrape_interval: {{ $interval }}
          static_configs:
            - targets: [{{ printf "%s:15692" (include "common.svcFqdn" (dict "ctx" . "name" (include "common.fullname" (dict "ctx" . "component" "rabbitmq")))) | toJson }}]
  {{- end }}
  {{- if $kafka }}
  kafka_metrics:
    brokers: ${env:KAFKA_BOOTSTRAP}
    {{- with $obs.kafkaProtocolVersion }}
    protocol_version: {{ . | toJson }}
    {{- end }}
    client_id: {{ include "otel.fullname" . | toJson }}
    cluster_alias: {{ include "common.fullname" (dict "ctx" . "component" "kafka") | toJson }}
    collection_interval: {{ $interval }}
    scrapers:
      - brokers
      - topics
      - consumers
    auth:
      sasl:
        mechanism: PLAIN
        username: ${env:KAFKA_USERNAME}
        password: ${env:KAFKA_PASSWORD}
    tls:
      ca_file: /etc/otel/kafka-ca/ca.crt
  {{- end }}

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: {{ dig "memoryLimiter" "limitPercentage" 80 $obs }}
    spike_limit_percentage: {{ dig "memoryLimiter" "spikeLimitPercentage" 20 $obs }}
  batch:
    send_batch_size: 8192
    timeout: 5s
  resource/otlp:
    {{- include "otel.resourceAttributes" (dict "ctx" . "component" (ternary "s3" "" $rustfs) "action" "insert") | nindent 4 }}
  {{- if $clickhouse }}
  resource/clickhouse:
    {{- include "otel.resourceAttributes" (dict "ctx" . "component" "clickhouse") | nindent 4 }}
  {{- end }}
  {{- if $kafka }}
  resource/kafka:
    {{- include "otel.resourceAttributes" (dict "ctx" . "component" "kafka") | nindent 4 }}
  {{- end }}
  {{- if $rabbitmq }}
  resource/rabbitmq:
    {{- include "otel.resourceAttributes" (dict "ctx" . "component" "rabbitmq") | nindent 4 }}
  {{- end }}

exporters:
  otlp_http:
    endpoint: {{ $endpoint | toJson }}
    {{- with $obs.headers }}
    headers:
      {{- $i := 0 }}
      {{- range $name, $_ := . }}
      {{ $name | toJson }}: {{ printf "${env:%s}" (include "otel.headerEnv" $i) | toJson }}
      {{- $i = add1 $i }}
      {{- end }}
    {{- end }}
    {{- if hasPrefix "https://" $endpoint }}
    tls:
      insecure_skip_verify: {{ dig "tls" "insecureSkipVerify" false $obs }}
      {{- if dig "tls" "ca" "" $obs }}
      ca_file: /etc/otel/exporter-ca/ca.crt
      {{- end }}
    {{- end }}
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true

service:
  extensions: [health_check]
  telemetry:
    logs:
      level: {{ $obs.logLevel | default "info" }}
  pipelines:
    {{- if ne (toString (dig "metrics" true $signals)) "false" }}
    metrics/otlp:
      receivers: [otlp]
      processors: [memory_limiter, resource/otlp, batch]
      exporters: [otlp_http]
    {{- end }}
    {{- if ne (toString (dig "traces" true $signals)) "false" }}
    traces/otlp:
      receivers: [otlp]
      processors: [memory_limiter, resource/otlp, batch]
      exporters: [otlp_http]
    {{- end }}
    {{- if ne (toString (dig "logs" true $signals)) "false" }}
    logs/otlp:
      receivers: [otlp]
      processors: [memory_limiter, resource/otlp, batch]
      exporters: [otlp_http]
    {{- end }}
    {{- if $clickhouse }}
    metrics/clickhouse:
      receivers: [prometheus/clickhouse]
      processors: [memory_limiter, resource/clickhouse, batch]
      exporters: [otlp_http]
    {{- end }}
    {{- if $rabbitmq }}
    metrics/rabbitmq:
      receivers: [prometheus/rabbitmq]
      processors: [memory_limiter, resource/rabbitmq, batch]
      exporters: [otlp_http]
    {{- end }}
    {{- if $kafka }}
    metrics/kafka:
      receivers: [kafka_metrics]
      processors: [memory_limiter, resource/kafka, batch]
      exporters: [otlp_http]
    {{- end }}
{{- end -}}
