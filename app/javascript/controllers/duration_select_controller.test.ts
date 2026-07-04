import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import DurationSelectController from "./duration_select_controller"
import { waitForController } from "../test/setup"

describe("DurationSelectController", () => {
  let application: Application

  beforeEach(() => {
    document.body.innerHTML = ""
    application = Application.start()
    application.register("duration-select", DurationSelectController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  function render(selected: string) {
    document.body.innerHTML = `
      <div data-controller="duration-select">
        <select name="duration_minutes" data-duration-select-target="select" data-action="change->duration-select#toggle">
          <option value="60"${selected === "60" ? " selected" : ""}>1 hour</option>
          <option value=""${selected === "" ? " selected" : ""}>Custom end time (multi-day)</option>
        </select>
        <div data-duration-select-target="customFields" style="display: none;">
          <input type="datetime-local" name="ends_at">
        </div>
      </div>
    `
  }

  it("hides custom end fields when a preset duration is selected", async () => {
    render("60")
    await waitForController()

    const fields = document.querySelector("[data-duration-select-target='customFields']") as HTMLElement
    expect(fields.style.display).toBe("none")
  })

  it("shows custom end fields when the custom option is selected", async () => {
    render("60")
    await waitForController()

    const select = document.querySelector("select") as HTMLSelectElement
    select.value = ""
    select.dispatchEvent(new Event("change"))

    const fields = document.querySelector("[data-duration-select-target='customFields']") as HTMLElement
    expect(fields.style.display).toBe("")
  })

  it("shows custom end fields on connect if custom is preselected", async () => {
    render("")
    await waitForController()

    const fields = document.querySelector("[data-duration-select-target='customFields']") as HTMLElement
    expect(fields.style.display).toBe("")
  })
})
