import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import HideOnErrorController from "./hide_on_error_controller"

describe("HideOnErrorController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("hide-on-error", HideOnErrorController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  async function mount() {
    // Mirrors the avatar-fallback usage: an <img> that hides itself if the
    // src fails to load, leaving the underlying initials visible.
    document.body.innerHTML = `
      <div class="avatar">
        <span class="initials">DA</span>
        <img src="/missing.png" class="img"
             data-controller="hide-on-error"
             data-action="error->hide-on-error#hide">
      </div>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  it("hides the element when the error event fires", async () => {
    await mount()
    const img = document.querySelector(".img") as HTMLElement
    expect(img.style.display).toBe("")

    img.dispatchEvent(new Event("error", { bubbles: false }))
    expect(img.style.display).toBe("none")
  })
})
