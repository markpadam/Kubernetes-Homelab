{{- define "blob-explorer.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "blob-explorer.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "blob-explorer.labels" -}}
app.kubernetes.io/name: {{ include "blob-explorer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{- define "blob-explorer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "blob-explorer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
