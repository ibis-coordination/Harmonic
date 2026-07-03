import { describe, expect, it } from "vitest"
import { cacheName, classify, staleCacheNames, type RequestSummary } from "./strategies"

const ORIGIN = "https://app.harmonic.local"

function req(overrides: Partial<RequestSummary> = {}): RequestSummary {
  return {
    url: `${ORIGIN}/`,
    method: "GET",
    mode: "no-cors",
    destination: "",
    accept: "*/*",
    ...overrides,
  }
}

describe("classify", () => {
  it("routes fingerprinted assets cache-first", () => {
    const info = req({ url: `${ORIGIN}/assets/application-abc123.js`, destination: "script" })
    expect(classify(info, ORIGIN)).toBe("cache-first")
  })

  it("routes stylesheets and fonts cache-first by destination", () => {
    expect(classify(req({ url: `${ORIGIN}/assets/pulse-def456.css`, destination: "style" }), ORIGIN)).toBe("cache-first")
    expect(classify(req({ url: `${ORIGIN}/assets/mono-789.woff2`, destination: "font" }), ORIGIN)).toBe("cache-first")
  })

  it("routes HTML navigations network-first", () => {
    const info = req({ url: `${ORIGIN}/n/abc123`, mode: "navigate", destination: "document", accept: "text/html" })
    expect(classify(info, ORIGIN)).toBe("network-first")
  })

  it("passes non-GET requests through", () => {
    const info = req({ url: `${ORIGIN}/n/abc123`, method: "POST" })
    expect(classify(info, ORIGIN)).toBe("network-only")
  })

  it("passes auth paths through even as navigations", () => {
    for (const path of ["/login", "/login/verify-2fa", "/logout", "/auth/github/callback"]) {
      const info = req({ url: `${ORIGIN}${path}`, mode: "navigate", destination: "document", accept: "text/html" })
      expect(classify(info, ORIGIN), path).toBe("network-only")
    }
  })

  it("passes Turbo Stream requests through", () => {
    const info = req({ url: `${ORIGIN}/n/abc123`, accept: "text/vnd.turbo-stream.html, text/html" })
    expect(classify(info, ORIGIN)).toBe("network-only")
  })

  it("passes API JSON through", () => {
    expect(classify(req({ url: `${ORIGIN}/api/v1/notes` }), ORIGIN)).toBe("network-only")
    expect(classify(req({ url: `${ORIGIN}/n/abc123`, accept: "application/json" }), ORIGIN)).toBe("network-only")
  })

  it("passes the service worker and manifest through", () => {
    for (const path of ["/service-worker.js", "/service-worker", "/manifest.json", "/manifest"]) {
      expect(classify(req({ url: `${ORIGIN}${path}` }), ORIGIN), path).toBe("network-only")
    }
  })

  it("passes cross-origin requests through", () => {
    const info = req({ url: "https://cdn.example.com/lib.js", destination: "script" })
    expect(classify(info, ORIGIN)).toBe("network-only")
  })

  it("passes unclassified same-origin GETs through", () => {
    expect(classify(req({ url: `${ORIGIN}/some.xml` }), ORIGIN)).toBe("network-only")
  })
})

describe("cacheName", () => {
  it("namespaces the cache by version", () => {
    expect(cacheName("abc123")).toBe("harmonic-abc123")
  })
})

describe("staleCacheNames", () => {
  it("selects harmonic caches from other versions", () => {
    const names = ["harmonic-old1", "harmonic-old2", "harmonic-current"]
    expect(staleCacheNames(names, "current")).toEqual(["harmonic-old1", "harmonic-old2"])
  })

  it("leaves caches it does not own alone", () => {
    expect(staleCacheNames(["other-cache", "harmonic-current"], "current")).toEqual([])
  })
})
