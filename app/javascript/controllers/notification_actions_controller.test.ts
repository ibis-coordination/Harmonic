import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import NotificationActionsController from "./notification_actions_controller"

function setupDOM() {
  document.body.innerHTML = `
    <div data-controller="notification-actions">
      <span data-notification-summary>
        <strong data-notification-actions-target="unreadCount">2</strong> unread notifications
      </span>
      <button data-notification-actions-target="markAllReadButton"
              data-action="click->notification-actions#markAllRead">Mark all read</button>
      <button data-notification-actions-target="dismissAllButton"
              data-action="click->notification-actions#dismissAll">Dismiss all</button>
      <details data-collective-group="c1">
        <summary>
          <span class="pulse-accordion-count">(2)</span>
          <button data-action="click->notification-actions#markReadForCollective" data-collective-id="c1">Mark all read</button>
        </summary>
        <div data-notification-item="n1" data-collective-id="c1" class="pulse-notification pulse-notification-unread">
          <div class="pulse-notification-indicator"></div>
          <a href="#" data-action="click->notification-actions#markReadOnNavigate" data-notification-id="n1">First</a>
          <button data-mark-read-button data-action="click->notification-actions#markRead" data-notification-id="n1">Mark read</button>
          <button data-action="click->notification-actions#dismiss" data-notification-id="n1">Dismiss</button>
        </div>
        <div data-notification-item="n2" data-collective-id="c1" class="pulse-notification pulse-notification-unread">
          <div class="pulse-notification-indicator"></div>
          <a href="#" data-action="click->notification-actions#markReadOnNavigate" data-notification-id="n2">Second</a>
          <button data-mark-read-button data-action="click->notification-actions#markRead" data-notification-id="n2">Mark read</button>
          <button data-action="click->notification-actions#dismiss" data-notification-id="n2">Dismiss</button>
        </div>
      </details>
    </div>
  `
}

function item(id: string): HTMLElement | null {
  return document.querySelector(`[data-notification-item="${id}"]`)
}

function summaryText(): string {
  return document.querySelector("[data-notification-summary]")?.textContent?.replace(/\s+/g, " ").trim() ?? ""
}

describe("NotificationActionsController", () => {
  let application: Application
  let mockFetch: ReturnType<typeof vi.fn>

  beforeEach(async () => {
    mockFetch = vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({ count: 2 }) })
    vi.stubGlobal("fetch", mockFetch)
    setupDOM()
    application = Application.start()
    application.register("notification-actions", NotificationActionsController)
    // Let Stimulus connect
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  describe("markRead", () => {
    it("marks the row read without removing it", async () => {
      const button = item("n1")?.querySelector("[data-mark-read-button]") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalledWith(
          "/notifications/actions/mark_read",
          expect.objectContaining({ method: "POST", body: "id=n1" }),
        )
      })

      await vi.waitFor(() => {
        const row = item("n1")
        expect(row).not.toBeNull()
        expect(row?.classList.contains("pulse-notification-unread")).toBe(false)
        expect(row?.querySelector(".pulse-notification-indicator")).toBeNull()
        expect(row?.querySelector("[data-mark-read-button]")).toBeNull()
        expect(summaryText()).toBe("1 unread notifications")
      })
    })

    it("dispatches notifications:changed so the badge refreshes", async () => {
      const listener = vi.fn()
      window.addEventListener("notifications:changed", listener)

      const button = item("n1")?.querySelector("[data-mark-read-button]") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => expect(listener).toHaveBeenCalled())
      window.removeEventListener("notifications:changed", listener)
    })
  })

  describe("markReadOnNavigate", () => {
    it("fires a keepalive mark_read request when the notification link is clicked", () => {
      const link = item("n2")?.querySelector("a") as HTMLAnchorElement
      link.addEventListener("click", (e) => e.preventDefault()) // jsdom: suppress navigation
      link.click()

      expect(mockFetch).toHaveBeenCalledWith(
        "/notifications/actions/mark_read",
        expect.objectContaining({ method: "POST", body: "id=n2", keepalive: true }),
      )
    })
  })

  describe("markAllRead", () => {
    it("marks every row read, zeroes the count, and keeps rows visible", async () => {
      const button = document.querySelector("[data-notification-actions-target='markAllReadButton']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalledWith(
          "/notifications/actions/mark_all_read",
          expect.objectContaining({ method: "POST" }),
        )
      })

      await vi.waitFor(() => {
        expect(item("n1")).not.toBeNull()
        expect(item("n2")).not.toBeNull()
        expect(item("n1")?.classList.contains("pulse-notification-unread")).toBe(false)
        expect(item("n2")?.classList.contains("pulse-notification-unread")).toBe(false)
        expect(summaryText()).toBe("No unread notifications")
        expect(button.style.display).toBe("none")
      })
    })

    it("keeps the dismiss all button visible while rows remain", async () => {
      const markAllReadButton = document.querySelector("[data-notification-actions-target='markAllReadButton']") as HTMLButtonElement
      const dismissAllButton = document.querySelector("[data-notification-actions-target='dismissAllButton']") as HTMLButtonElement
      markAllReadButton.click()

      await vi.waitFor(() => expect(summaryText()).toBe("No unread notifications"))
      expect(dismissAllButton.style.display).not.toBe("none")
    })
  })

  describe("markReadForCollective", () => {
    it("marks rows in the collective read and decrements the count by the response count", async () => {
      const button = document.querySelector("[data-collective-id='c1'][data-action*='markReadForCollective']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        expect(mockFetch).toHaveBeenCalledWith(
          "/notifications/actions/mark_read_for_collective",
          expect.objectContaining({ method: "POST", body: "collective_id=c1" }),
        )
      })

      await vi.waitFor(() => {
        expect(item("n1")?.classList.contains("pulse-notification-unread")).toBe(false)
        expect(item("n2")?.classList.contains("pulse-notification-unread")).toBe(false)
        expect(item("n1")).not.toBeNull()
        expect(summaryText()).toBe("No unread notifications")
      })
    })
  })

  describe("dismiss with read rows", () => {
    it("keeps the dismiss all button visible when the unread count reaches 0 but rows remain", async () => {
      const dismissAllButton = document.querySelector("[data-notification-actions-target='dismissAllButton']") as HTMLButtonElement

      const b1 = item("n1")?.querySelector("[data-mark-read-button]") as HTMLButtonElement
      b1.click()
      await vi.waitFor(() => expect(summaryText()).toBe("1 unread notifications"))
      const b2 = item("n2")?.querySelector("[data-mark-read-button]") as HTMLButtonElement
      b2.click()
      await vi.waitFor(() => expect(summaryText()).toBe("No unread notifications"))

      expect(item("n1")).not.toBeNull()
      expect(item("n2")).not.toBeNull()
      expect(dismissAllButton.style.display).not.toBe("none")
    })
  })
})
