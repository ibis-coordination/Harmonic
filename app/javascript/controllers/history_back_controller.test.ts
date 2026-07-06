import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import HistoryBackController from "./history_back_controller"

describe("HistoryBackController", () => {
  let application: Application
  let backSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    application = Application.start()
    application.register("history-back", HistoryBackController)
    backSpy = vi.spyOn(window.history, "back").mockImplementation(() => {})
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  async function mount(extraAttrs = "") {
    document.body.innerHTML = `
      <a href="/fallback" class="btn"
         data-controller="history-back"
         data-action="click->history-back#back"
         ${extraAttrs}>Cancel</a>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  it("calls window.history.back() and prevents the default navigation", async () => {
    await mount()
    const link = document.querySelector(".btn") as HTMLAnchorElement
    const ev = new MouseEvent("click", { bubbles: true, cancelable: true })
    link.dispatchEvent(ev)
    expect(backSpy).toHaveBeenCalledTimes(1)
    expect(ev.defaultPrevented).toBe(true)
  })

  describe("reveal-when-history", () => {
    afterEach(() => {
      vi.unstubAllGlobals()
    })

    it("adds the revealed class when there is history to go back to", async () => {
      vi.stubGlobal("history", { length: 2, back: () => {} })
      await mount('data-history-back-revealed-class="is-visible"')
      const link = document.querySelector(".btn") as HTMLAnchorElement
      expect(link.classList.contains("is-visible")).toBe(true)
    })

    it("leaves the control hidden when there is no earlier entry", async () => {
      vi.stubGlobal("history", { length: 1, back: () => {} })
      await mount('data-history-back-revealed-class="is-visible"')
      const link = document.querySelector(".btn") as HTMLAnchorElement
      expect(link.classList.contains("is-visible")).toBe(false)
    })

    it("does not touch classes when no revealed class is configured", async () => {
      vi.stubGlobal("history", { length: 5, back: () => {} })
      await mount()
      const link = document.querySelector(".btn") as HTMLAnchorElement
      expect(link.className).toBe("btn")
    })
  })
})
