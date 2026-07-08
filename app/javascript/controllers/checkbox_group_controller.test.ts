import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import CheckboxGroupController from "./checkbox_group_controller"

describe("CheckboxGroupController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("checkbox-group", CheckboxGroupController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  async function mount(checked: boolean[]) {
    const boxes = checked
      .map(
        (isChecked, i) => `
        <input type="checkbox" id="m${i}" ${isChecked ? "checked" : ""}
               data-checkbox-group-target="checkbox"
               data-action="change->checkbox-group#syncToggle">`
      )
      .join("")
    document.body.innerHTML = `
      <div data-controller="checkbox-group">
        <input type="checkbox" id="toggle"
               data-checkbox-group-target="toggle"
               data-action="change->checkbox-group#toggleAll">
        ${boxes}
      </div>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  const toggle = () => document.getElementById("toggle") as HTMLInputElement
  const box = (i: number) => document.getElementById(`m${i}`) as HTMLInputElement

  function clickToggle(checked: boolean) {
    toggle().checked = checked
    toggle().dispatchEvent(new Event("change", { bubbles: true }))
  }

  function setBox(i: number, checked: boolean) {
    box(i).checked = checked
    box(i).dispatchEvent(new Event("change", { bubbles: true }))
  }

  it("toggling on checks every member; toggling off unchecks them", async () => {
    await mount([false, false, false])

    clickToggle(true)
    expect([box(0).checked, box(1).checked, box(2).checked]).toEqual([true, true, true])

    clickToggle(false)
    expect([box(0).checked, box(1).checked, box(2).checked]).toEqual([false, false, false])
  })

  it("connect() reflects all-checked as a checked toggle", async () => {
    await mount([true, true, true])
    expect(toggle().checked).toBe(true)
    expect(toggle().indeterminate).toBe(false)
  })

  it("a partial selection makes the toggle indeterminate", async () => {
    await mount([true, false, false])
    expect(toggle().checked).toBe(false)
    expect(toggle().indeterminate).toBe(true)
  })

  it("checking the last member clears indeterminate and checks the toggle", async () => {
    await mount([true, true, false])
    expect(toggle().indeterminate).toBe(true)

    setBox(2, true)
    expect(toggle().checked).toBe(true)
    expect(toggle().indeterminate).toBe(false)
  })

  it("none checked leaves the toggle unchecked and not indeterminate", async () => {
    await mount([false, false, false])
    expect(toggle().checked).toBe(false)
    expect(toggle().indeterminate).toBe(false)
  })
})
