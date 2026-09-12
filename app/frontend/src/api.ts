// API client for the Idea Board backend.
//
// The API base URL is resolved with this precedence:
//   1. Runtime override: window.__ENV__.VITE_API_BASE_URL, injected by the
//      nginx container at startup (see public/env-config.js + entrypoint). This
//      lets one built image target different backends per deployment.
//   2. Build-time env: import.meta.env.VITE_API_BASE_URL (useful for local dev).
//   3. Default: http://localhost:8000 (matches the docker-compose contract).
//
// An explicitly provided EMPTY string means "same origin" — the SPA calls a
// relative /api/ideas. That is the behind-an-ingress case (frontend + API share
// the load balancer origin), so no absolute URL / CORS is needed.

export interface Idea {
  id: number;
  content: string;
  created_at: string;
}

declare global {
  interface Window {
    __ENV__?: {
      VITE_API_BASE_URL?: string;
    };
  }
}

export function getApiBaseUrl(): string {
  const runtime =
    typeof window !== "undefined" ? window.__ENV__?.VITE_API_BASE_URL : undefined;
  const buildTime = import.meta.env.VITE_API_BASE_URL;

  // A value that is DEFINED (even "") wins — "" = same origin (relative). Only
  // fall back to the localhost dev default when nothing was provided at all.
  const resolved =
    runtime !== undefined ? runtime : buildTime !== undefined ? buildTime : "http://localhost:8000";

  // Normalize away a trailing slash so path concatenation is predictable.
  return resolved.replace(/\/+$/, "");
}

async function parseError(res: Response, fallback: string): Promise<string> {
  try {
    const data = (await res.json()) as { detail?: unknown };
    if (typeof data.detail === "string") {
      return data.detail;
    }
  } catch {
    // Body was not JSON; fall through to the generic message.
  }
  return `${fallback} (HTTP ${res.status})`;
}

export async function fetchIdeas(): Promise<Idea[]> {
  const res = await fetch(`${getApiBaseUrl()}/api/ideas`, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) {
    throw new Error(await parseError(res, "Failed to load ideas"));
  }
  return (await res.json()) as Idea[];
}

export async function createIdea(content: string): Promise<Idea> {
  const res = await fetch(`${getApiBaseUrl()}/api/ideas`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ content }),
  });
  if (!res.ok) {
    throw new Error(await parseError(res, "Failed to submit idea"));
  }
  return (await res.json()) as Idea;
}
