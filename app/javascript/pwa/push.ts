// Pure logic for handling incoming push events and notification clicks.
// Kept free of service-worker globals so it can be unit tested.

export interface PushPayload {
  title: string
  body?: string
  url?: string
  icon?: string
  badge?: string
  notification_type?: string
  notification_id?: string
}

const DEFAULT_TITLE = "Harmonic"

export function parsePayload(raw: unknown): PushPayload {
  if (typeof raw !== "object" || raw === null) return { title: DEFAULT_TITLE }

  const data = raw as Record<string, unknown>
  const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined)

  return {
    title: str(data.title) || DEFAULT_TITLE,
    body: str(data.body),
    url: str(data.url),
    icon: str(data.icon),
    badge: str(data.badge),
    notification_type: str(data.notification_type),
    notification_id: str(data.notification_id),
  }
}

export interface PushNotificationOptions {
  body?: string
  icon?: string
  badge?: string
  data: { url?: string }
}

export function notificationOptions(payload: PushPayload): PushNotificationOptions {
  return {
    body: payload.body,
    icon: payload.icon,
    badge: payload.badge,
    data: { url: payload.url },
  }
}

// Decide whether an incoming push should surface an OS notification, given
// the open windows on this origin. When the user has a window focused they
// are actively in the app, and the in-app channel (bell badge, chat view) is
// already showing the content — a banner on top of that is noise, worst for
// chat, which pushes per message. Chrome's userVisibleOnly requirement has an
// explicit carve-out for skipping the notification while a window is focused.
//
// Cross-origin targets always show: delivery is origin-agnostic, so another
// tenant's notification can arrive at this service worker, and a focused
// window here says nothing about whether the user can see that content.
// Url-less payloads originate from this origin's server, so they follow the
// same-origin rule.
export function shouldShowNotification(
  targetUrl: string | undefined,
  clients: { focused: boolean }[],
  origin: string,
): boolean {
  if (!clients.some((client) => client.focused)) return true
  if (!targetUrl) return false

  try {
    return new URL(targetUrl).origin !== origin
  } catch {
    return false
  }
}

export type ClickAction =
  | { type: "focus"; index: number }
  | { type: "focus-navigate"; index: number }
  | { type: "open" }

// Decide what a notification click should do given the open windows.
// Focusing (and navigating) only works same-origin; a deep link into another
// tenant's subdomain always opens a new window.
export function clickAction(targetUrl: string, clientUrls: string[], origin: string): ClickAction {
  let target: URL
  try {
    target = new URL(targetUrl)
  } catch {
    return { type: "open" }
  }
  if (target.origin !== origin) return { type: "open" }

  const exact = clientUrls.findIndex((url) => url === targetUrl)
  if (exact >= 0) return { type: "focus", index: exact }

  if (clientUrls.length > 0) return { type: "focus-navigate", index: 0 }

  return { type: "open" }
}
