#!/bin/sh
# Runtime environment injection for the SPA.
#
# nginx serves a static, pre-built bundle, but the API base URL must be
# configurable per deployment WITHOUT rebuilding the image (12-factor). This
# script rewrites /env-config.js from $VITE_API_BASE_URL on every container
# start; the app reads window.__ENV__.VITE_API_BASE_URL at load time (src/api.ts).
#
# The official nginx image runs executable scripts in /docker-entrypoint.d/
# before launching nginx, so this file lives there.
set -eu

# Use '-' (not ':-') so an explicitly-set EMPTY value is preserved: "" means
# same-origin (relative /api/ideas) for behind-an-ingress deploys. Only an
# UNSET var falls back to the localhost dev default (docker-compose).
API_BASE_URL="${VITE_API_BASE_URL-http://localhost:8000}"
CONFIG_PATH="/usr/share/nginx/html/env-config.js"

cat > "$CONFIG_PATH" <<EOF
window.__ENV__ = { VITE_API_BASE_URL: "${API_BASE_URL}" };
EOF

echo "[env-config] wrote ${CONFIG_PATH} with VITE_API_BASE_URL=${API_BASE_URL}"
