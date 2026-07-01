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
