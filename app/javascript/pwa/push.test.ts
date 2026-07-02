import { describe, expect, it } from "vitest"
import { clickAction, notificationOptions, parsePayload, shouldShowNotification } from "./push"

const ORIGIN = "https://app.harmonic.local"

describe("parsePayload", () => {
  it("passes through a full payload", () => {
    const payload = parsePayload({
      title: "Ada mentioned you",
      body: "Some note",
      url: `${ORIGIN}/n/abc`,
      icon: "/harmonic-icon-192.png",
      notification_type: "mention",
    })
    expect(payload.title).toBe("Ada mentioned you")
    expect(payload.url).toBe(`${ORIGIN}/n/abc`)
  })

  it("defaults the title and tolerates junk", () => {
    expect(parsePayload(null).title).toBe("Harmonic")
    expect(parsePayload("nonsense").title).toBe("Harmonic")
    expect(parsePayload({ title: 42 }).title).toBe("Harmonic")
  })
})

describe("notificationOptions", () => {
  it("maps payload fields onto notification options with the url in data", () => {
    const options = notificationOptions(parsePayload({
      title: "T",
      body: "B",
      url: `${ORIGIN}/n/abc`,
      icon: "/icon.png",
      badge: "/badge.png",
    }))
    expect(options.body).toBe("B")
    expect(options.icon).toBe("/icon.png")
    expect(options.badge).toBe("/badge.png")
    expect(options.data.url).toBe(`${ORIGIN}/n/abc`)
  })
})

describe("shouldShowNotification", () => {
  const focused = { focused: true }
  const blurred = { focused: false }

  it("shows when no window is open", () => {
    expect(shouldShowNotification(`${ORIGIN}/n/abc`, [], ORIGIN)).toBe(true)
  })

  it("shows when windows are open but none is focused", () => {
    expect(shouldShowNotification(`${ORIGIN}/n/abc`, [blurred, blurred], ORIGIN)).toBe(true)
  })

  it("suppresses a same-origin notification when a window is focused", () => {
    // The user is actively in the app on this tenant; the in-app channel
    // (bell badge, chat view) is already showing the content.
    expect(shouldShowNotification(`${ORIGIN}/n/abc`, [blurred, focused], ORIGIN)).toBe(false)
  })

  it("shows a cross-origin notification even when a window is focused", () => {
    // Delivery is origin-agnostic: tenant B's notification can arrive at
    // tenant A's service worker. A focused tenant-A window says nothing
    // about whether the user can see tenant B's content.
    expect(shouldShowNotification("https://other.harmonic.local/n/abc", [focused], ORIGIN)).toBe(true)
  })

  it("suppresses url-less and unparseable-url notifications when focused", () => {
    expect(shouldShowNotification(undefined, [focused], ORIGIN)).toBe(false)
    expect(shouldShowNotification("::not a url::", [focused], ORIGIN)).toBe(false)
  })
})

describe("clickAction", () => {
  it("focuses the client already at the target URL", () => {
    const action = clickAction(`${ORIGIN}/n/abc`, [`${ORIGIN}/`, `${ORIGIN}/n/abc`], ORIGIN)
    expect(action).toEqual({ type: "focus", index: 1 })
  })

  it("focuses and navigates an existing same-origin client", () => {
    const action = clickAction(`${ORIGIN}/n/abc`, [`${ORIGIN}/`], ORIGIN)
    expect(action).toEqual({ type: "focus-navigate", index: 0 })
  })

  it("opens a window when no client exists", () => {
    expect(clickAction(`${ORIGIN}/n/abc`, [], ORIGIN)).toEqual({ type: "open" })
  })

  it("opens a window for cross-origin targets even with clients present", () => {
    const action = clickAction("https://other.harmonic.local/n/abc", [`${ORIGIN}/`], ORIGIN)
    expect(action).toEqual({ type: "open" })
  })
})
