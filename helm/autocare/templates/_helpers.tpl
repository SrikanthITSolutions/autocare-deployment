{{/*
Base chart name.
*/}}
{{- define "autocare.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. Used as the base name for all created resources.
*/}}
{{- define "autocare.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version, used in the helm.sh/chart label.
*/}}
{{- define "autocare.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "autocare.labels" -}}
helm.sh/chart: {{ include "autocare.chart" . }}
{{ include "autocare.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: autocare
app.kubernetes.io/environment: {{ .Values.environment }}
{{- end -}}

{{/*
Selector labels - kept minimal and immutable, used in Deployment/Service/HPA/PDB selectors.
*/}}
{{- define "autocare.selectorLabels" -}}
app.kubernetes.io/name: {{ include "autocare.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
ServiceAccount name to use.
*/}}
{{- define "autocare.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "autocare.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
