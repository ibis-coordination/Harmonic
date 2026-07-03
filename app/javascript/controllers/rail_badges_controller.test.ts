import { describe, it, expect, beforeEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import RailBadgesController from "./rail_badges_controller"

describe("RailBadgesController", () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <nav class="pulse-rail" data-controller="rail-badges">
        <a href="/chat">
          <span class="pulse-rail-badge" data-chat-badge style="display: none"></span>
        </a>
        <a href="/collectives/team-a">
          <span class="pulse-rail-badge" data-collective-id="aaa-111" style="display: none"></span>
        </a>
        <a href="/collectives/team-b">
          <span class="pulse-rail-badge" data-collective-id="bbb-222" style="display: none"></span>
        </a>
      </nav>
    `
    const application = Application.start()
    application.register("rail-badges", RailBadgesController)
  })

  function badge(collectiveId: string): HTMLElement {
    return document.querySelector(`.pulse-rail-badge[data-collective-id='${collectiveId}']`) as HTMLElement
  }

  function broadcast(byCollective: Record<string, number>, chat = 0): void {
    window.dispatchEvent(new CustomEvent("notifications:counts", { detail: { byCollective, chat } }))
  }

  function chatBadge(): HTMLElement {
    return document.querySelector("[data-chat-badge]") as HTMLElement
  }

  it("shows counts on squares with unread notifications", async () => {
    broadcast({ "aaa-111": 4 })

    await vi.waitFor(() => {
      expect(badge("aaa-111").textContent).toBe("4")
      expect(badge("aaa-111").style.display).toBe("")
    })
  })

  it("hides badges for collectives with no unread notifications", async () => {
    broadcast({ "aaa-111": 4, "bbb-222": 2 })
    await vi.waitFor(() => expect(badge("bbb-222").style.display).toBe(""))

    broadcast({ "aaa-111": 4 })

    await vi.waitFor(() => {
      expect(badge("aaa-111").style.display).toBe("")
      expect(badge("bbb-222").style.display).toBe("none")
    })
  })

  it("caps the displayed count at 99+", async () => {
    broadcast({ "aaa-111": 250 })

    await vi.waitFor(() => {
      expect(badge("aaa-111").textContent).toBe("99+")
    })
  })

  it("fills and clears the aggregated chat badge", async () => {
    broadcast({}, 5)
    await vi.waitFor(() => {
      expect(chatBadge().textContent).toBe("5")
      expect(chatBadge().style.display).toBe("")
    })

    broadcast({}, 0)
    await vi.waitFor(() => {
      expect(chatBadge().style.display).toBe("none")
    })
  })
})
