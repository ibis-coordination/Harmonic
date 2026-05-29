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
})
