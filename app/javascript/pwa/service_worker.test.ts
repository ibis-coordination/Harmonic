import { afterEach, describe, expect, it, vi } from "vitest"

// The entrypoint registers listeners on the service-worker global scope at
// import time; stub the scope, import fresh, and fire events at the captured
// listeners.

type Listener = (event: unknown) => void

function stubScope() {
  const listeners = new Map<string, Listener>()
  const scope = {
    CACHE_VERSION: "test",
    location: { origin: "https://app.harmonic.local" },
    registration: { showNotification: vi.fn(async () => undefined) },
    skipWaiting: vi.fn(async () => undefined),
    clients: {
      claim: vi.fn(async () => undefined),
      matchAll: vi.fn(async () => []),
      openWindow: vi.fn(async () => undefined),
    },
    addEventListener: (type: string, listener: Listener) => listeners.set(type, listener),
  }
  const cache = { add: vi.fn(async () => undefined) }
  vi.stubGlobal("self", scope)
  vi.stubGlobal("caches", {
    open: async () => cache,
    keys: async () => [],
    delete: async () => true,
  })
  return { scope, listeners, cache }
}

async function fire(listeners: Map<string, Listener>, type: string): Promise<void> {
  const waits: Promise<unknown>[] = []
  listeners.get(type)!({ waitUntil: (promise: Promise<unknown>) => waits.push(promise) })
  await Promise.all(waits)
}

describe("push", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.resetModules()
  })

  it("shows the notification even when a window is focused", async () => {
    // iOS counts a push that produces no visible notification as a strike
    // and silently revokes the subscription after three (issue #397). A
    // focused-window carve-out is never safe there — suspended PWA clients
    // can keep reporting focused: true — so every push shows.
    const { scope, listeners } = stubScope()
    scope.clients.matchAll = vi.fn(async () => [
      { url: "https://app.harmonic.local/", focused: true },
    ]) as never
    await import("./service_worker")

    const waits: Promise<unknown>[] = []
    listeners.get("push")!({
      waitUntil: (promise: Promise<unknown>) => waits.push(promise),
      data: { json: () => ({ title: "Ping", url: "https://app.harmonic.local/n/abc" }) },
    })
    await Promise.all(waits)

    expect(scope.registration.showNotification).toHaveBeenCalledWith(
      "Ping",
      expect.objectContaining({ data: { url: "https://app.harmonic.local/n/abc" } }),
    )
  })
})

describe("service worker lifecycle", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.resetModules()
  })

  it("skips waiting on install so a new version takes over without a full tab-close cycle", async () => {
    const { scope, listeners, cache } = stubScope()
    await import("./service_worker")

    await fire(listeners, "install")

    expect(scope.skipWaiting).toHaveBeenCalled()
    expect(cache.add).toHaveBeenCalledWith("/offline")
  })

  it("claims open clients on activate", async () => {
    const { scope, listeners } = stubScope()
    await import("./service_worker")

    await fire(listeners, "activate")

    expect(scope.clients.claim).toHaveBeenCalled()
  })
})
