import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import NotificationBadgeController from "./notification_badge_controller"

describe("NotificationBadgeController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()

    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="notification-badge" data-notification-badge-poll-interval-value="5000">
        <span data-notification-badge-target="count" style="display: none;">0</span>
      </div>
    `

    // Start Stimulus application
    application = Application.start()
    application.register("notification-badge", NotificationBadgeController)
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("initializes with the count target", () => {
    const countElement = document.querySelector("[data-notification-badge-target='count']") as HTMLElement
    expect(countElement).toBeDefined()
    expect(countElement.textContent).toBe("0")
  })

  it("updates badge when count is received", async () => {
    // Mock fetch to return a count
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ count: 5 }),
    })
    vi.stubGlobal("fetch", mockFetch)

    // Advance timer to trigger poll
    await vi.advanceTimersByTimeAsync(5000)

    const countElement = document.querySelector("[data-notification-badge-target='count']") as HTMLElement

    // Wait for the fetch to complete
    await vi.waitFor(() => {
      expect(countElement.textContent).toBe("5")
      expect(countElement.style.display).toBe("")
    })
  })

  it("hides badge when count is zero", async () => {
    // Mock fetch to return zero count
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ count: 0 }),
    })
    vi.stubGlobal("fetch", mockFetch)

    // Advance timer to trigger poll
    await vi.advanceTimersByTimeAsync(5000)

    const countElement = document.querySelector("[data-notification-badge-target='count']") as HTMLElement

    await vi.waitFor(() => {
      expect(countElement.textContent).toBe("0")
      expect(countElement.style.display).toBe("none")
    })
  })

  it("polls at the configured interval", async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ count: 1 }),
    })
    vi.stubGlobal("fetch", mockFetch)

    // Get initial call count after any startup calls
    const initialCalls = mockFetch.mock.calls.length

    // Advance timer multiple times and check that calls increment
    await vi.advanceTimersByTimeAsync(5000)
    const afterFirst = mockFetch.mock.calls.length
    expect(afterFirst).toBeGreaterThan(initialCalls)

    await vi.advanceTimersByTimeAsync(5000)
    const afterSecond = mockFetch.mock.calls.length
    expect(afterSecond).toBeGreaterThan(afterFirst)

    await vi.advanceTimersByTimeAsync(5000)
    const afterThird = mockFetch.mock.calls.length
    expect(afterThird).toBeGreaterThan(afterSecond)
  })

  it("handles fetch errors gracefully", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("Network error"))
    vi.stubGlobal("fetch", mockFetch)

    const countElement = document.querySelector("[data-notification-badge-target='count']") as HTMLElement
    const initialDisplay = countElement.style.display

    // Advance timer to trigger poll
    await vi.advanceTimersByTimeAsync(5000)

    // Should not throw and badge should remain unchanged
    expect(countElement.style.display).toBe(initialDisplay)
  })
})
