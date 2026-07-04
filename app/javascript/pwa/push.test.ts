import { describe, expect, it } from "vitest"
import { clickAction, notificationOptions, parsePayload } from "./push"

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
