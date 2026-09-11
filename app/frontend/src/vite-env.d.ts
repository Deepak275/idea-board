/// <reference types="vite/client" />

// Build-time environment variables exposed to the client via import.meta.env.
interface ImportMetaEnv {
  readonly VITE_API_BASE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
