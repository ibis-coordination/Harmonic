import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import NoteController from "./note_controller"
import { waitForController } from "../test/setup"

describe("NoteController", () => {
  let application: Application

  beforeEach(() => {
    document.body.innerHTML = ""
    application = Application.start()
    application.register("note", NoteController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  function renderConfirmSection() {
    document.body.innerHTML = `
      <span data-controller="note">
        <div data-note-target="confirmSection">
          <button
            data-action="click->note#confirm mouseenter->note#confirmButtonMouseEnter mouseleave->note#confirmButtonMouseLeave"
            data-note-target="confirmButton"
            data-url="/n/abc123/confirm.html">
            <span data-note-target="confirmButtonMessage">Confirm Read</span>
          </button>
        </div>
      </span>
    `
  }

  function captureErrors(): Error[] {
    const errors: Error[] = []
    application.handleError = (error: Error) => {
      errors.push(error)
    }
    return errors
  }

  it("underlines the button message on hover", async () => {
    renderConfirmSection()
    await waitForController()

    const button = document.querySelector("[data-note-target='confirmButton']") as HTMLElement
    const message = document.querySelector("[data-note-target='confirmButtonMessage']") as HTMLElement

    button.dispatchEvent(new MouseEvent("mouseenter"))
    expect(message.style.textDecoration).toBe("underline")

    button.dispatchEvent(new MouseEvent("mouseleave"))
    expect(message.style.textDecoration).toBe("")
  })

  it("tolerates hover after the button message is replaced mid-confirm", async () => {
    renderConfirmSection()
    await waitForController()
    const errors = captureErrors()

    // confirm() swaps the button's innerHTML for a pending message, dropping the
    // message span while the button and its hover bindings are still live.
    const button = document.querySelector("[data-note-target='confirmButton']") as HTMLElement
    button.innerHTML = "Confirming..."

    button.dispatchEvent(new MouseEvent("mouseenter"))
    button.dispatchEvent(new MouseEvent("mouseleave"))

    expect(errors).toEqual([])
  })
})
