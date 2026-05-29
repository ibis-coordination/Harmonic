import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import RemoveParentController from "./remove_parent_controller"

describe("RemoveParentController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("remove-parent", RemoveParentController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  async function mount() {
    // Mirrors the flash-dismiss pattern in app/views/layouts/application.html.erb:
    // an × button inside a flash container removes the whole flash on click.
    document.body.innerHTML = `
      <div class="pulse-flash-messages">
        <div class="pulse-notice" id="flash">
          A notice
          <button type="button" class="dismiss"
                  data-controller="remove-parent"
                  data-action="click->remove-parent#remove">&times;</button>
        </div>
      </div>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  it("removes the button's parent element when clicked", async () => {
    await mount()
    expect(document.getElementById("flash")).not.toBeNull()
    ;(document.querySelector(".dismiss") as HTMLButtonElement).click()
    expect(document.getElementById("flash")).toBeNull()
  })

  it("leaves siblings of the parent intact", async () => {
    document.body.innerHTML = `
      <div id="container">
        <div id="other">stays</div>
        <div id="flash">
          <button class="dismiss"
                  data-controller="remove-parent"
                  data-action="click->remove-parent#remove">&times;</button>
        </div>
      </div>
    `
    await new Promise((r) => setTimeout(r, 0))
    ;(document.querySelector(".dismiss") as HTMLButtonElement).click()
    expect(document.getElementById("flash")).toBeNull()
    expect(document.getElementById("other")).not.toBeNull()
    expect(document.getElementById("container")).not.toBeNull()
  })
})
