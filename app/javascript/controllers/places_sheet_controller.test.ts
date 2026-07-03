import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import PlacesSheetController from "./places_sheet_controller"

describe("PlacesSheetController", () => {
  let application: Application

  afterEach(() => {
    application.stop()
  })

  beforeEach(() => {
    document.body.innerHTML = `
      <div data-controller="places-sheet">
        <button data-places-sheet-target="toggle" data-action="click->places-sheet#toggle"
                aria-expanded="false">
          Places
          <span data-places-sheet-target="dot" style="display: none"></span>
        </button>
        <div data-places-sheet-target="backdrop" data-action="click->places-sheet#close" hidden></div>
        <div class="pulse-places-sheet" data-places-sheet-target="panel" aria-hidden="true"></div>
      </div>
    `
    application = Application.start()
    application.register("places-sheet", PlacesSheetController)
  })

  function el(target: string): HTMLElement {
    return document.querySelector(`[data-places-sheet-target='${target}']`) as HTMLElement
  }

  it("opens and closes from the toggle button", async () => {
    el("toggle").click()
    await vi.waitFor(() => {
      expect(el("panel").getAttribute("aria-hidden")).toBe("false")
      expect(el("panel").classList.contains("open")).toBe(true)
      expect(el("backdrop").hidden).toBe(false)
      expect(el("toggle").getAttribute("aria-expanded")).toBe("true")
    })

    el("toggle").click()
    await vi.waitFor(() => {
      expect(el("panel").getAttribute("aria-hidden")).toBe("true")
      expect(el("panel").classList.contains("open")).toBe(false)
      expect(el("backdrop").hidden).toBe(true)
      expect(el("toggle").getAttribute("aria-expanded")).toBe("false")
    })
  })

  it("closes on backdrop click and on Escape", async () => {
    el("toggle").click()
    await vi.waitFor(() => expect(el("panel").classList.contains("open")).toBe(true))

    el("backdrop").click()
    await vi.waitFor(() => expect(el("panel").classList.contains("open")).toBe(false))

    el("toggle").click()
    await vi.waitFor(() => expect(el("panel").classList.contains("open")).toBe(true))

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }))
    await vi.waitFor(() => expect(el("panel").classList.contains("open")).toBe(false))
  })

  it("shows the aggregate dot when any place has unread activity", async () => {
    window.dispatchEvent(
      new CustomEvent("notifications:counts", {
        detail: { byCollective: { "aaa-111": 2 }, chat: 0 },
      }),
    )
    await vi.waitFor(() => expect(el("dot").style.display).toBe(""))

    window.dispatchEvent(
      new CustomEvent("notifications:counts", {
        detail: { byCollective: {}, chat: 0 },
      }),
    )
    await vi.waitFor(() => expect(el("dot").style.display).toBe("none"))

    window.dispatchEvent(
      new CustomEvent("notifications:counts", {
        detail: { byCollective: {}, chat: 3 },
      }),
    )
    await vi.waitFor(() => expect(el("dot").style.display).toBe(""))
  })
})
