{{- define "juicefs-stack.name" -}}
juicefs-stack
{{- end }}

{{- define "juicefs-stack.labels" -}}
app.kubernetes.io/name: {{ include "juicefs-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
