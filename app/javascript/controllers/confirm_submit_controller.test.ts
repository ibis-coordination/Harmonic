import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import ConfirmSubmitController from "./confirm_submit_controller"

describe("ConfirmSubmitController", () => {
  let application: Application
  let confirmSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    application = Application.start()
    application.register("confirm-submit", ConfirmSubmitController)
    confirmSpy = vi.spyOn(window, "confirm")
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  async function mountButton(message = "Are you sure?") {
    document.body.innerHTML = `
      <form id="f" action="/x" method="post">
        <button type="submit" id="btn"
                data-controller="confirm-submit"
                data-confirm-submit-message-value="${message}"
                data-action="click->confirm-submit#prompt">Go</button>
      </form>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  async function mountForm(message = "Are you sure?") {
    document.body.innerHTML = `
      <form id="f" action="/x" method="post"
            data-controller="confirm-submit"
            data-confirm-submit-message-value="${message}"
            data-action="submit->confirm-submit#prompt">
        <button type="submit" id="btn">Go</button>
      </form>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  it("clicking the button shows the configured confirm message", async () => {
    await mountButton("Really delete?")
    confirmSpy.mockReturnValue(true)
    ;(document.getElementById("btn") as HTMLButtonElement).click()
    expect(confirmSpy).toHaveBeenCalledWith("Really delete?")
  })

  it("OK on the dialog lets the click default through (form would submit)", async () => {
    await mountButton()
    confirmSpy.mockReturnValue(true)
    const ev = new MouseEvent("click", { bubbles: true, cancelable: true })
    document.getElementById("btn")!.dispatchEvent(ev)
    expect(ev.defaultPrevented).toBe(false)
  })

  it("Cancel on the dialog preventDefaults (the form does NOT submit)", async () => {
    await mountButton()
    confirmSpy.mockReturnValue(false)
    const ev = new MouseEvent("click", { bubbles: true, cancelable: true })
    document.getElementById("btn")!.dispatchEvent(ev)
    expect(ev.defaultPrevented).toBe(true)
  })

  it("wired on a form's submit event also works (Cancel preventDefaults the submit)", async () => {
    await mountForm("Really?")
    confirmSpy.mockReturnValue(false)
    const ev = new Event("submit", { bubbles: true, cancelable: true })
    document.getElementById("f")!.dispatchEvent(ev)
    expect(confirmSpy).toHaveBeenCalledWith("Really?")
    expect(ev.defaultPrevented).toBe(true)
  })

  it("wired on a form's submit event: OK lets the submit proceed", async () => {
    await mountForm()
    confirmSpy.mockReturnValue(true)
    const ev = new Event("submit", { bubbles: true, cancelable: true })
    document.getElementById("f")!.dispatchEvent(ev)
    expect(ev.defaultPrevented).toBe(false)
  })
})
