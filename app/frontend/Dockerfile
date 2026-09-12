# syntax=docker/dockerfile:1

###############################################################################
# Build stage: compile the Vite + React + TypeScript app to static assets.
###############################################################################
FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies first for better layer caching.
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Build the production bundle into /app/dist.
COPY . .
RUN npm run build

###############################################################################
# Runtime stage: serve the SPA with nginx as a NON-ROOT user on port 80.
###############################################################################
FROM nginx:alpine AS runtime

# Patch Alpine packages (current security fixes), then install libcap — setcap
# lets the unprivileged nginx user bind privileged port 80 without running as root.
RUN apk upgrade --no-cache && apk add --no-cache libcap

# SPA-aware server config (routing + caching + security headers).
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Static assets from the build stage.
COPY --from=build /app/dist /usr/share/nginx/html

# Runtime env injection: writes /env-config.js from $VITE_API_BASE_URL at start.
COPY docker-entrypoint.sh /docker-entrypoint.d/40-env-config.sh

RUN chmod +x /docker-entrypoint.d/40-env-config.sh \
    # Grant the nginx binary permission to bind port 80 as a non-root user.
    && setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx \
    # Make the paths nginx and the entrypoint write to owned by the nginx user.
    && chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

# Drop privileges: run as the built-in unprivileged nginx user (uid 101).
USER nginx

EXPOSE 80

# Uses the base image ENTRYPOINT (/docker-entrypoint.sh, which runs the scripts
# in /docker-entrypoint.d/) and CMD (nginx -g 'daemon off;').
