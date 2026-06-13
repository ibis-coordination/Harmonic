import { describe, it, expect, beforeEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import HandleInputController from "./handle_input_controller"

describe("HandleInputController", () => {
  beforeEach(async () => {
    const application = Application.start()
    application.register("handle-input", HandleInputController)
    document.body.innerHTML = `
      <input data-controller="handle-input" data-action="input->handle-input#sanitize" value="" />
    `
    // Let Stimulus connect
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  function type(value: string): HTMLInputElement {
    const input = document.querySelector("input") as HTMLInputElement
    input.value = value
    input.dispatchEvent(new Event("input", { bubbles: true }))
    return input
  }

  it("lowercases and converts spaces to dashes", () => {
    expect(type("Jane Smith").value).toBe("jane-smith")
  })

  it("strips characters outside a-z0-9_-", () => {
    expect(type('jane.*^[|"smith!').value).toBe("janesmith")
  })

  it("leaves valid handles untouched", () => {
    expect(type("jane-smith_42").value).toBe("jane-smith_42")
  })
})
