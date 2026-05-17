{{- define "blob-explorer.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "blob-explorer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
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
