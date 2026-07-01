// Service worker entrypoint. Built by esbuild to app/assets/builds/pwa/,
// then inlined by app/views/pwa/service_worker.js.erb below a
// `self.CACHE_VERSION = "<git sha>"` line — per-deploy cache busting.

import { respondCacheFirst, respondNetworkFirst } from "./handlers"
import { cacheName, classify, OFFLINE_PATH, staleCacheNames, type RequestSummary } from "./strategies"

interface ServiceWorkerScope {
  CACHE_VERSION?: string
  location: Location
  clients: { claim(): Promise<void> }
  addEventListener(type: string, listener: (event: never) => void): void
}

interface ExtendableEventLike {
  waitUntil(promise: Promise<unknown>): void
}

interface FetchEventLike extends ExtendableEventLike {
  request: Request
  respondWith(response: Promise<Response>): void
}

const sw = self as unknown as ServiceWorkerScope
const VERSION = sw.CACHE_VERSION || "dev"
const CACHE = cacheName(VERSION)

function toRequestSummary(request: Request): RequestSummary {
  return {
    url: request.url,
    method: request.method,
    mode: request.mode,
    destination: request.destination,
    accept: request.headers.get("accept") || "",
  }
}

sw.addEventListener("install", (event: ExtendableEventLike) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.add(OFFLINE_PATH)))
})

sw.addEventListener("activate", (event: ExtendableEventLike) => {
  event.waitUntil(
    (async () => {
      const stale = staleCacheNames(await caches.keys(), VERSION)
      await Promise.all(stale.map((name) => caches.delete(name)))
      await sw.clients.claim()
    })(),
  )
})

sw.addEventListener("fetch", (event: FetchEventLike) => {
  const strategy = classify(toRequestSummary(event.request), sw.location.origin)
  if (strategy === "network-only") return

  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE)
      if (strategy === "cache-first") {
        return respondCacheFirst(cache, event.request, (req) => fetch(req))
      }
      return respondNetworkFirst(cache, event.request, (req) => fetch(req), OFFLINE_PATH)
    })(),
  )
})
