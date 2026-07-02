import { describe, expect, it, vi } from "vitest"
import { subscribeToPush, urlBase64ToUint8Array, type SubscribeDeps } from "./subscribe"

function fakeSubscription(overrides: { applicationServerKey?: Uint8Array; unsubscribe?: () => Promise<boolean> } = {}) {
  return {
    toJSON: () => ({ endpoint: "https://push.example.com/send/abc", keys: { p256dh: "k", auth: "a" } }),
    options: overrides.applicationServerKey ? { applicationServerKey: overrides.applicationServerKey.buffer } : {},
    unsubscribe: overrides.unsubscribe ?? (async () => true),
  } as unknown as PushSubscription
}

function deps(overrides: Partial<SubscribeDeps> = {}): SubscribeDeps & { posts: Array<{ url: string; body: unknown }> } {
  const posts: Array<{ url: string; body: unknown }> = []
  return {
    posts,
    vapidPublicKey: "BPd6HDwGDrqBnbmZhZuT1Yc6mkWSHFJZfmiJqZUxWQZfQzD-Zh0aJutFYc9O2ZguJALhx1nlWJDjxqGmFvDf0Zs",
    requestPermission: async () => "granted" as NotificationPermission,
    getSubscription: async () => null,
    subscribe: async () => fakeSubscription(),
    post: async (url: string, body: unknown) => {
      posts.push({ url, body })
      return true
    },
    postUrl: "/u/ada/settings/push-subscriptions",
    ...overrides,
  }
}

describe("urlBase64ToUint8Array", () => {
  it("decodes url-safe base64 into bytes", () => {
    const bytes = urlBase64ToUint8Array("AQID")
    expect(Array.from(bytes)).toEqual([1, 2, 3])
  })

  it("handles url-safe characters and padding", () => {
    const bytes = urlBase64ToUint8Array("_-8")
    expect(Array.from(bytes)).toEqual([255, 239])
  })
})

describe("subscribeToPush", () => {
  it("subscribes and POSTs the subscription", async () => {
    const d = deps()
    const result = await subscribeToPush(d)

    expect(result).toBe("subscribed")
    expect(d.posts).toHaveLength(1)
    expect(d.posts[0].url).toBe("/u/ada/settings/push-subscriptions")
    expect(d.posts[0].body).toEqual({
      subscription: { endpoint: "https://push.example.com/send/abc", keys: { p256dh: "k", auth: "a" } },
    })
  })

  it("reuses an existing subscription minted with the current key", async () => {
    const subscribeFn = vi.fn()
    const d = deps({})
    const currentKey = urlBase64ToUint8Array(d.vapidPublicKey)
    d.getSubscription = async () => fakeSubscription({ applicationServerKey: currentKey })
    d.subscribe = subscribeFn

    const result = await subscribeToPush(d)

    expect(result).toBe("subscribed")
    expect(subscribeFn).not.toHaveBeenCalled()
    expect(d.posts).toHaveLength(1)
  })

  it("replaces a subscription minted with a different (rotated) VAPID key", async () => {
    const unsubscribe = vi.fn(async () => true)
    const d = deps({})
    d.getSubscription = async () => fakeSubscription({ applicationServerKey: new Uint8Array([9, 9, 9]), unsubscribe })
    const subscribeFn = vi.fn(async () => fakeSubscription())
    d.subscribe = subscribeFn

    const result = await subscribeToPush(d)

    expect(result).toBe("subscribed")
    expect(unsubscribe).toHaveBeenCalledOnce()
    expect(subscribeFn).toHaveBeenCalledOnce()
    expect(d.posts).toHaveLength(1)
  })

  it("keeps an existing subscription whose key cannot be read", async () => {
    // No options.applicationServerKey exposed (older browsers) — don't churn.
    const subscribeFn = vi.fn()
    const d = deps({ getSubscription: async () => fakeSubscription(), subscribe: subscribeFn })

    expect(await subscribeToPush(d)).toBe("subscribed")
    expect(subscribeFn).not.toHaveBeenCalled()
  })

  it("reports denied permission without subscribing", async () => {
    const subscribeFn = vi.fn()
    const d = deps({ requestPermission: async () => "denied" as NotificationPermission, subscribe: subscribeFn })

    const result = await subscribeToPush(d)

    expect(result).toBe("permission-denied")
    expect(subscribeFn).not.toHaveBeenCalled()
    expect(d.posts).toHaveLength(0)
  })

  it("reports errors from the push service", async () => {
    const d = deps({ subscribe: async () => { throw new Error("push service says no") } })

    expect(await subscribeToPush(d)).toBe("error")
    expect(d.posts).toHaveLength(0)
  })
})
