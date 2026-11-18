{{- define "rabbitmq.fullname" -}}
{{- include "common.fullname" (dict "ctx" . "component" "rabbitmq") -}}
{{- end -}}
{{- define "rabbitmq.headless" -}}
{{- include "common.fullname" (dict "ctx" . "component" "rabbitmq-headless") -}}
{{- end -}}
{{- define "rabbitmq.credentialsSecret" -}}
{{- include "common.fullname" (dict "ctx" . "component" "rabbitmq-credentials") -}}
{{- end -}}
{{- define "rabbitmq.tlsSecret" -}}
{{- include "common.tls.secretName" (dict "ctx" . "component" "rabbitmq" "existingSecret" .Values.rabbitmq.tls.existingSecret) -}}
{{- end -}}
{{- define "rabbitmq.nodeName" -}}
{{- printf "rabbit@%s-0.%s.%s.svc.%s" (include "rabbitmq.fullname" .) (include "rabbitmq.headless" .) .Release.Namespace (include "common.clusterDomain" .) -}}
{{- end -}}
{{- define "rabbitmq.password" -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "rabbitmq.credentialsSecret" .) "key" "password" "value" .Values.rabbitmq.auth.password "length" 32) -}}
{{- end -}}
{{- define "rabbitmq.cookie" -}}
{{- include "common.secretValue" (dict "ctx" . "secret" (include "rabbitmq.credentialsSecret" .) "key" "erlang-cookie" "value" .Values.rabbitmq.auth.erlangCookie "length" 48) -}}
{{- end -}}
{{- define "rabbitmq.validate" -}}
{{- if ne (int .Values.rabbitmq.replicas) 1 -}}
{{- fail "The MES 11.3 RabbitMQ chart requires rabbitmq.replicas=1; clustering is not configured." -}}
{{- end -}}
{{- if or (empty .Values.rabbitmq.auth.username) (eq .Values.rabbitmq.auth.username "guest") (empty .Values.rabbitmq.virtualHost) -}}
{{- fail "RabbitMQ needs a non-guest username and a nonempty virtualHost." -}}
{{- end -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "rabbitmq.credentialsSecret" .) -}}
{{- range $key, $desired := dict "username" .Values.rabbitmq.auth.username "virtual-host" .Values.rabbitmq.virtualHost "node-name" (include "rabbitmq.nodeName" .) "erlang-cookie" (include "rabbitmq.cookie" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data $key) -}}
{{- if ne (index $existing.data $key | b64dec) $desired -}}
{{- fail (printf "RabbitMQ %s cannot change while reusing its retained credentials and data." $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
