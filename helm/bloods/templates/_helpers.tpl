{{- define "bloods.name" -}}bloods{{- end -}}
{{- define "bloods.labels" -}}
app.kubernetes.io/name: bloods
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
