// Service worker entrypoint. Built by esbuild to app/assets/builds/pwa/,
// then inlined by app/views/pwa/service_worker.js.erb below a
// `self.CACHE_VERSION = "<git sha>"` line — per-deploy cache busting.

import { respondCacheFirst, respondNetworkFirst } from "./handlers"
import { clickAction, notificationOptions, parsePayload } from "./push"
import { cacheName, classify, OFFLINE_PATH, staleCacheNames, type RequestSummary } from "./strategies"

interface WindowClientLike {
  url: string
  focus(): Promise<unknown>
  navigate(url: string): Promise<unknown>
}

interface ServiceWorkerScope {
  CACHE_VERSION?: string
  location: Location
  navigator?: { setAppBadge?: (count?: number) => Promise<void> }
  registration: { showNotification(title: string, options?: object): Promise<void> }
  clients: {
    claim(): Promise<void>
    matchAll(options?: { type?: string; includeUncontrolled?: boolean }): Promise<WindowClientLike[]>
    openWindow(url: string): Promise<unknown>
  }
  addEventListener(type: string, listener: (event: never) => void): void
}

interface ExtendableEventLike {
  waitUntil(promise: Promise<unknown>): void
}

interface FetchEventLike extends ExtendableEventLike {
  request: Request
  respondWith(response: Promise<Response>): void
}

interface PushEventLike extends ExtendableEventLike {
  data: { json(): unknown } | null
}

interface NotificationClickEventLike extends ExtendableEventLike {
  notification: { close(): void; data?: { url?: string } }
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

sw.addEventListener("push", (event: PushEventLike) => {
  let raw: unknown = null
  try {
    raw = event.data?.json() ?? null
  } catch {
    raw = null
  }
  const payload = parsePayload(raw)

  event.waitUntil(
    (async () => {
      await sw.registration.showNotification(payload.title, notificationOptions(payload))
      // iOS surfaces the app badge on the home-screen icon; harmless no-op elsewhere.
      await sw.navigator?.setAppBadge?.().catch(() => undefined)
    })(),
  )
})

sw.addEventListener("notificationclick", (event: NotificationClickEventLike) => {
  event.notification.close()
  const url = event.notification.data?.url
  if (!url) return

  event.waitUntil(
    (async () => {
      const clients = await sw.clients.matchAll({ type: "window", includeUncontrolled: true })
      const action = clickAction(url, clients.map((client) => client.url), sw.location.origin)
      switch (action.type) {
        case "focus":
          await clients[action.index].focus()
          break
        case "focus-navigate": {
          const client = clients[action.index]
          await client.focus()
          await client.navigate(url)
          break
        }
        case "open":
          await sw.clients.openWindow(url)
      }
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
