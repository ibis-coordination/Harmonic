import { describe, expect, it, vi } from "vitest"
import { respondCacheFirst, respondNetworkFirst, type CacheLike } from "./handlers"

function fakeResponse(status = 200): Response {
  return { status, ok: status >= 200 && status < 300 } as unknown as Response
}

function fakeCache(entries: Record<string, Response> = {}): CacheLike & { putCalls: Array<[string, Response]> } {
  const putCalls: Array<[string, Response]> = []
  return {
    putCalls,
    match: async (key: string) => entries[key],
    put: async (key: string, response: Response) => {
      putCalls.push([key, response])
    },
  }
}

const REQ = "https://app.harmonic.local/assets/application-abc.js"

describe("respondCacheFirst", () => {
  it("returns the cached response without fetching", async () => {
    const cached = fakeResponse()
    const cache = fakeCache({ [REQ]: cached })
    const fetchFn = vi.fn()

    expect(await respondCacheFirst(cache, REQ, fetchFn)).toBe(cached)
    expect(fetchFn).not.toHaveBeenCalled()
  })

  it("fetches and caches a copy on miss", async () => {
    const cache = fakeCache()
    const fresh = fakeResponse()
    const clone = fakeResponse()
    ;(fresh as unknown as { clone: () => Response }).clone = () => clone
    const fetchFn = vi.fn(async () => fresh)

    expect(await respondCacheFirst(cache, REQ, fetchFn)).toBe(fresh)
    expect(cache.putCalls).toEqual([[REQ, clone]])
  })

  it("does not cache non-200 responses", async () => {
    const cache = fakeCache()
    const fetchFn = vi.fn(async () => fakeResponse(404))

    await respondCacheFirst(cache, REQ, fetchFn)
    expect(cache.putCalls).toEqual([])
  })
})

describe("respondNetworkFirst", () => {
  const NAV = "https://app.harmonic.local/n/abc123"

  it("returns the network response when the network is up", async () => {
    const fresh = fakeResponse()
    const cache = fakeCache()
    const fetchFn = vi.fn(async () => fresh)

    expect(await respondNetworkFirst(cache, NAV, fetchFn, "/offline")).toBe(fresh)
  })

  it("passes HTTP error responses through without fallback", async () => {
    const error = fakeResponse(500)
    const cache = fakeCache({ "/offline": fakeResponse() })
    const fetchFn = vi.fn(async () => error)

    expect(await respondNetworkFirst(cache, NAV, fetchFn, "/offline")).toBe(error)
  })

  it("falls back to the cached offline page when the network fails", async () => {
    const offline = fakeResponse()
    const cache = fakeCache({ "/offline": offline })
    const fetchFn = vi.fn(async () => {
      throw new TypeError("Failed to fetch")
    })

    expect(await respondNetworkFirst(cache, NAV, fetchFn, "/offline")).toBe(offline)
  })

  it("rethrows when the network fails and no offline page is cached", async () => {
    const cache = fakeCache()
    const fetchFn = vi.fn(async () => {
      throw new TypeError("Failed to fetch")
    })

    await expect(respondNetworkFirst(cache, NAV, fetchFn, "/offline")).rejects.toThrow("Failed to fetch")
  })
})
