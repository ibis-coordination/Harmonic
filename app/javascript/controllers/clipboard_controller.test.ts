import { describe, it, expect, beforeEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import ClipboardController from "./clipboard_controller"

describe("ClipboardController", () => {
  let application: Application

  beforeEach(() => {
    // Mock clipboard API
    Object.assign(navigator, {
      clipboard: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
    })

    // Set up DOM with targets
    document.body.innerHTML = `
      <div data-controller="clipboard">
        <input data-clipboard-target="source" value="text to copy" />
        <button data-clipboard-target="button" data-action="click->clipboard#copy">Copy</button>
        <span data-clipboard-target="successMessage" style="display: none;">Copied!</span>
      </div>
    `

    // Start Stimulus application
    application = Application.start()
    application.register("clipboard", ClipboardController)
  })

  it("copies text to clipboard when copy is called", async () => {
    const button = document.querySelector("[data-clipboard-target='button']") as HTMLButtonElement
    button.click()

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("text to copy")
  })

  it("shows success message and hides button after copy", async () => {
    const button = document.querySelector("[data-clipboard-target='button']") as HTMLElement
    const successMessage = document.querySelector("[data-clipboard-target='successMessage']") as HTMLElement

    button.click()

    // Wait for clipboard promise to resolve
    await vi.waitFor(() => {
      expect(button.style.display).toBe("none")
      expect(successMessage.style.display).toBe("inline")
    })
  })
})
