// Background push-subscription resync, run once per page load.
//
// The server only hears about a subscription when the user clicks "Enable on
// this device" — after that, the two sides drift silently: last_seen_at goes
// stale, the push service can rotate the endpoint, and iOS can revoke the
// subscription outright without telling anyone (issue #397). Re-posting the
// browser's subscription on every load keeps the server's row honest, and
// when permission is still granted but the subscription is gone, re-creating
// it restores what the user asked for — the standing permission grant is the
// consent. The server side treats a resync as a refresh, never a re-enable:
// it won't revive a row the user (or an admin) revoked.
//
// Browser APIs and the network are injected so the flow can be unit tested;
// wirePushResync builds the real ones from the layout's meta tags.

import { fetchWithCsrf } from "../utils/csrf"
import { mintedWithKey, urlBase64ToUint8Array } from "./subscribe"

export type ResyncResult = "synced" | "resubscribed" | "skipped" | "error"

export interface ResyncDeps {
  postUrl: string | null | undefined
  vapidPublicKey: string | null | undefined
  permission: NotificationPermission
  getSubscription: () => Promise<PushSubscription | null>
  subscribe: (options: { userVisibleOnly: boolean; applicationServerKey: Uint8Array<ArrayBuffer> }) => Promise<PushSubscription>
  post: (url: string, body: unknown) => Promise<boolean>
}

export async function resyncPushSubscription(deps: ResyncDeps): Promise<ResyncResult> {
  if (!deps.postUrl || !deps.vapidPublicKey) return "skipped"
  if (deps.permission !== "granted") return "skipped"

  try {
    const currentKey = urlBase64ToUint8Array(deps.vapidPublicKey)
    let subscription = await deps.getSubscription()
    // A subscription minted with a rotated VAPID key can't deliver, but
    // replacing it is the explicit re-enable flow's job — churning it on
    // every load would fight that flow.
    if (subscription && !mintedWithKey(subscription, currentKey)) return "skipped"

    let result: ResyncResult = "synced"
    if (!subscription) {
      subscription = await deps.subscribe({ userVisibleOnly: true, applicationServerKey: currentKey })
      result = "resubscribed"
    }

    const posted = await deps.post(deps.postUrl, { subscription: subscription.toJSON(), resync: true })
    return posted ? result : "error"
  } catch (error) {
    console.warn("Push subscription resync failed:", error)
    return "error"
  }
}

export function wirePushResync(): void {
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return

  const meta = (name: string): string | undefined =>
    (document.querySelector(`meta[name='${name}']`) as HTMLMetaElement | null)?.content
  // No subscription URL means push isn't available here (flag off, VAPID
  // unconfigured, signed out, or not a human user).
  const postUrl = meta("push-subscription-url")
  if (!postUrl) return

  window.addEventListener("load", () => {
    void (async () => {
      // .ready rather than getRegistration(): on a cold load the register()
      // call is still in flight, and getRegistration would resolve to
      // nothing. The subscription URL only renders when the service-worker
      // flag is on, so ready settles.
      const registration = await navigator.serviceWorker.ready
      await resyncPushSubscription({
        postUrl,
        vapidPublicKey: meta("vapid-public-key"),
        permission: Notification.permission,
        getSubscription: () => registration.pushManager.getSubscription(),
        subscribe: (options) => registration.pushManager.subscribe(options),
        post: async (url, body) => {
          const response = await fetchWithCsrf(url, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
          })
          return response.ok
        },
      })
    })()
  })
}
