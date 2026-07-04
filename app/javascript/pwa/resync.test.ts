import { describe, expect, it, vi } from "vitest"
import { resyncPushSubscription, type ResyncDeps } from "./resync"

const VAPID_KEY = "BPd6HDwGDrqBnbmZhZuT1Yc6mkWSHFJZfmiJqZUxWQZfQzD-Zh0aJutFYc9O2ZguJALhx1nlWJDjxqGmFvDf0Zs"

function fakeSubscription(overrides: { applicationServerKey?: Uint8Array } = {}) {
  return {
    toJSON: () => ({ endpoint: "https://push.example.com/send/abc", keys: { p256dh: "k", auth: "a" } }),
    options: overrides.applicationServerKey ? { applicationServerKey: overrides.applicationServerKey.buffer } : {},
  } as unknown as PushSubscription
}

function deps(overrides: Partial<ResyncDeps> = {}): ResyncDeps & { posts: Array<{ url: string; body: unknown }> } {
  const posts: Array<{ url: string; body: unknown }> = []
  return {
    posts,
    postUrl: "/u/ada/settings/push-subscriptions",
    vapidPublicKey: VAPID_KEY,
    permission: "granted" as NotificationPermission,
    getSubscription: async () => fakeSubscription(),
    subscribe: async () => fakeSubscription(),
    post: async (url: string, body: unknown) => {
      posts.push({ url, body })
      return true
    },
    ...overrides,
  }
}

describe("resyncPushSubscription", () => {
  it("re-posts the browser's subscription with the resync flag", async () => {
    const d = deps()

    expect(await resyncPushSubscription(d)).toBe("synced")
    expect(d.posts).toHaveLength(1)
    expect(d.posts[0].url).toBe("/u/ada/settings/push-subscriptions")
    expect(d.posts[0].body).toEqual({
      subscription: { endpoint: "https://push.example.com/send/abc", keys: { p256dh: "k", auth: "a" } },
      resync: true,
    })
  })

  it("re-subscribes when permission is granted but the subscription is gone", async () => {
    // The self-heal for iOS silently revoking a subscription: the standing
    // permission grant is the consent; minting a fresh transport identifier
    // under it restores what the user asked for.
    const subscribeFn = vi.fn(async () => fakeSubscription())
    const d = deps({ getSubscription: async () => null, subscribe: subscribeFn })

    expect(await resyncPushSubscription(d)).toBe("resubscribed")
    expect(subscribeFn).toHaveBeenCalledOnce()
    expect(d.posts).toHaveLength(1)
  })

  it("does nothing without permission", async () => {
    const d = deps({ permission: "default" as NotificationPermission })

    expect(await resyncPushSubscription(d)).toBe("skipped")
    expect(d.posts).toHaveLength(0)
  })

  it("does nothing without a post URL or VAPID key", async () => {
    expect(await resyncPushSubscription(deps({ postUrl: null }))).toBe("skipped")
    expect(await resyncPushSubscription(deps({ vapidPublicKey: null }))).toBe("skipped")
  })

  it("leaves a subscription minted with a different VAPID key alone", async () => {
    // Key rotation is repaired by the explicit re-enable flow (unsubscribe +
    // fresh subscribe); the background resync must not churn it every load.
    const d = deps({ getSubscription: async () => fakeSubscription({ applicationServerKey: new Uint8Array([9, 9, 9]) }) })

    expect(await resyncPushSubscription(d)).toBe("skipped")
    expect(d.posts).toHaveLength(0)
  })

  it("reports errors without throwing", async () => {
    expect(await resyncPushSubscription(deps({ post: async () => false }))).toBe("error")
    expect(
      await resyncPushSubscription(
        deps({ getSubscription: async () => null, subscribe: async () => { throw new Error("no") } }),
      ),
    ).toBe("error")
  })

  it("posts an existing subscription whose key cannot be read", async () => {
    // Older browsers expose no options.applicationServerKey — trust it, as
    // the subscribe flow does.
    const d = deps({ getSubscription: async () => fakeSubscription() })

    expect(await resyncPushSubscription(d)).toBe("synced")
    expect(d.posts).toHaveLength(1)
  })
})
