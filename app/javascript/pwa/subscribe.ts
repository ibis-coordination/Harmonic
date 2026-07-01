// Push subscription flow. Browser APIs and the network are injected so the
// flow can be unit tested; the Stimulus controller wires the real ones.

export type SubscribeResult = "subscribed" | "permission-denied" | "error"

export interface SubscribeDeps {
  vapidPublicKey: string
  postUrl: string
  requestPermission: () => Promise<NotificationPermission>
  getSubscription: () => Promise<PushSubscription | null>
  subscribe: (options: { userVisibleOnly: boolean; applicationServerKey: Uint8Array<ArrayBuffer> }) => Promise<PushSubscription>
  post: (url: string, body: unknown) => Promise<boolean>
}

export function urlBase64ToUint8Array(base64: string): Uint8Array<ArrayBuffer> {
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
  const raw = atob(padded.replace(/-/g, "+").replace(/_/g, "/"))
  const bytes = new Uint8Array(new ArrayBuffer(raw.length))
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
  return bytes
}

export async function subscribeToPush(deps: SubscribeDeps): Promise<SubscribeResult> {
  try {
    const permission = await deps.requestPermission()
    if (permission !== "granted") return "permission-denied"

    const subscription =
      (await deps.getSubscription()) ||
      (await deps.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(deps.vapidPublicKey),
      }))

    const posted = await deps.post(deps.postUrl, { subscription: subscription.toJSON() })
    return posted ? "subscribed" : "error"
  } catch (error) {
    console.warn("Push subscription failed:", error)
    return "error"
  }
}
