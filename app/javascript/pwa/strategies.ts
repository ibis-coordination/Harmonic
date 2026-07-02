// Pure request-classification logic for the service worker. Kept free of
// service-worker globals so it can be unit tested.

export type Strategy = "cache-first" | "network-first" | "network-only"

export interface RequestSummary {
  url: string
  method: string
  mode: string
  destination: string
  accept: string
}

export const OFFLINE_PATH = "/offline"

const CACHE_PREFIX = "harmonic-"

// Paths the SW must never intercept: its own delivery channel, the manifest,
// and the auth flow (login, OAuth bounce, logout, 2FA).
const PASSTHROUGH_PATHS = ["/service-worker", "/manifest", "/login", "/logout"]
const PASSTHROUGH_PREFIXES = ["/service-worker.", "/manifest.", "/login/", "/auth/", "/api/"]

const CACHEABLE_DESTINATIONS = new Set(["script", "style", "font"])

export function cacheName(version: string): string {
  return `${CACHE_PREFIX}${version}`
}

export function staleCacheNames(names: string[], version: string): string[] {
  const current = cacheName(version)
  return names.filter((name) => name.startsWith(CACHE_PREFIX) && name !== current)
}

export function classify(info: RequestSummary, origin: string): Strategy {
  if (info.method !== "GET") return "network-only"

  let url: URL
  try {
    url = new URL(info.url)
  } catch {
    return "network-only"
  }
  if (url.origin !== origin) return "network-only"

  const path = url.pathname
  if (PASSTHROUGH_PATHS.includes(path)) return "network-only"
  if (PASSTHROUGH_PREFIXES.some((prefix) => path.startsWith(prefix))) return "network-only"

  const accept = info.accept || ""
  if (accept.includes("text/vnd.turbo-stream.html")) return "network-only"
  if (accept.includes("application/json")) return "network-only"

  if (info.mode === "navigate" || info.destination === "document") return "network-first"

  if (path.startsWith("/assets/") || CACHEABLE_DESTINATIONS.has(info.destination)) return "cache-first"

  return "network-only"
}
