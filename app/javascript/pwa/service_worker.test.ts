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
