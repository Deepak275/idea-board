{{/*
_helpers.tpl — shared template helpers for the idea-board chart.

Naming: because the release name ("idea-board") already contains the chart name
("idea-board"), the fullname helper collapses to just "idea-board", yielding the
contract-mandated Service names "idea-board-backend" / "idea-board-frontend".
*/}}

{{/* Chart base name (overridable). */}}
{{- define "idea-board.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name (release-scoped, DNS-safe, <=63 chars). */}}
{{- define "idea-board.fullname" -}}
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

{{/* Chart label value "<name>-<version>". */}}
{{- define "idea-board.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels applied to every object. */}}
{{- define "idea-board.labels" -}}
helm.sh/chart: {{ include "idea-board.chart" . }}
{{ include "idea-board.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: idea-board
{{- end -}}

{{/* Selector labels shared by all components (never include version here). */}}
{{- define "idea-board.selectorLabels" -}}
app.kubernetes.io/name: {{ include "idea-board.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* ---- Backend component ---- */}}
{{- define "idea-board.backend.fullname" -}}
{{- printf "%s-backend" (include "idea-board.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "idea-board.backend.selectorLabels" -}}
{{ include "idea-board.selectorLabels" . }}
app.kubernetes.io/component: backend
{{- end -}}

{{- define "idea-board.backend.labels" -}}
{{ include "idea-board.labels" . }}
app.kubernetes.io/component: backend
{{- end -}}

{{- define "idea-board.backend.image" -}}
{{- $tag := .Values.backend.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.backend.image.repository $tag -}}
{{- end -}}

{{/* ---- Frontend component ---- */}}
{{- define "idea-board.frontend.fullname" -}}
{{- printf "%s-frontend" (include "idea-board.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "idea-board.frontend.selectorLabels" -}}
{{ include "idea-board.selectorLabels" . }}
app.kubernetes.io/component: frontend
{{- end -}}

{{- define "idea-board.frontend.labels" -}}
{{ include "idea-board.labels" . }}
app.kubernetes.io/component: frontend
{{- end -}}

{{- define "idea-board.frontend.image" -}}
{{- $tag := .Values.frontend.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.frontend.image.repository $tag -}}
{{- end -}}

{{/* ServiceAccount name to use. */}}
{{- define "idea-board.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "idea-board.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Public URL of the application. The browser-facing frontend and the API share a
single host (path-routed by the Ingress: "/api" -> backend, "/" -> frontend), so
this doubles as the frontend's API base URL and the backend's allowed CORS
origin. Falls back to the local docker-compose contract when no Ingress host is
configured.
*/}}
{{- define "idea-board.publicUrl" -}}
{{- if .Values.ingress.host -}}
{{- if .Values.ingress.tls.enabled -}}
https://{{ .Values.ingress.host }}
{{- else -}}
http://{{ .Values.ingress.host }}
{{- end -}}
{{- else -}}
http://localhost:8000
{{- end -}}
{{- end -}}

{{/* Frontend API base URL (explicit value wins, else derived public URL). */}}
{{- define "idea-board.apiBaseUrl" -}}
{{- .Values.frontend.apiBaseUrl | default (include "idea-board.publicUrl" .) -}}
{{- end -}}

{{/* Backend allowed CORS origins (explicit value wins, else derived public URL). */}}
{{- define "idea-board.corsOrigins" -}}
{{- .Values.backend.corsOrigins | default (include "idea-board.publicUrl" .) -}}
{{- end -}}
