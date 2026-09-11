// Runtime environment configuration.
//
// This is the DEFAULT/dev version of the file. In the production container it is
// overwritten at startup by the nginx entrypoint using $VITE_API_BASE_URL, so
// the same built image can point at different backends per deployment.
//
// Leaving VITE_API_BASE_URL unset here lets src/api.ts fall back to the
// build-time env var (import.meta.env) and finally to http://localhost:8000.
window.__ENV__ = window.__ENV__ || {};
