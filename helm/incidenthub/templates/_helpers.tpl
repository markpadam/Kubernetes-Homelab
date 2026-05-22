{{- define "incidenthub.name" -}}incidenthub{{- end -}}
{{- define "incidenthub.labels" -}}
app.kubernetes.io/name: incidenthub
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
