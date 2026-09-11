import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite configuration for the Idea Board SPA.
// Note: VITE_API_BASE_URL can be injected at BUILD time (import.meta.env) OR
// overridden at DEPLOY time via the runtime /env-config.js file (see src/api.ts
// and the nginx container entrypoint). This keeps the image 12-factor: one
// build artifact, environment-specific config supplied at runtime.
export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
  },
  preview: {
    host: true,
    port: 4173,
  },
  build: {
    outDir: "dist",
    sourcemap: false,
  },
});
