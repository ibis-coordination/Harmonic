import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import RadioToggleController from "./radio_toggle_controller"

describe("RadioToggleController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("radio-toggle", RadioToggleController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  async function mount() {
    document.body.innerHTML = `
      <section data-controller="radio-toggle"
               data-radio-toggle-hide-on-value="all">
        <input type="radio" name="m" value="all" id="all" checked
               data-action="change->radio-toggle#sync">
        <input type="radio" name="m" value="include" id="include"
               data-action="change->radio-toggle#sync">
        <input type="radio" name="m" value="exclude" id="exclude"
               data-action="change->radio-toggle#sync">
        <div data-radio-toggle-target="section" id="picker" style="display:none;">picker</div>
      </section>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  function section() {
    return document.getElementById("picker") as HTMLElement
  }

  function pick(id: string) {
    const radio = document.getElementById(id) as HTMLInputElement
    radio.checked = true
    radio.dispatchEvent(new Event("change", { bubbles: true }))
  }

  it("selecting the hide-on value hides the section", async () => {
    await mount()
    pick("include")
    expect(section().style.display).toBe("block")
    pick("all")
    expect(section().style.display).toBe("none")
  })

  it("selecting a non-hide-on value shows the section", async () => {
    await mount()
    pick("exclude")
    expect(section().style.display).toBe("block")
  })

  it("initial state: connect() reconciles to the checked radio (matches hide-on → hidden)", async () => {
    await mount()
    // Mount has 'all' checked and hide-on='all'; section starts display:none
    // and connect's reconcile keeps it that way.
    expect(section().style.display).toBe("none")
  })

  it("connect() flips a stale cached-snapshot display to match the currently-checked radio", async () => {
    // Simulates a Turbo Drive snapshot restore where the user had previously
    // selected 'include' but the server-rendered display:none didn't update.
    document.body.innerHTML = `
      <section data-controller="radio-toggle"
               data-radio-toggle-hide-on-value="all">
        <input type="radio" name="m" value="all" id="all"
               data-action="change->radio-toggle#sync">
        <input type="radio" name="m" value="include" id="include" checked
               data-action="change->radio-toggle#sync">
        <div data-radio-toggle-target="section" id="picker" style="display:none;">picker</div>
      </section>
    `
    await new Promise((r) => setTimeout(r, 0))
    expect(section().style.display).toBe("block")
  })
})
