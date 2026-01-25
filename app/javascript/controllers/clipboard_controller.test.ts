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

    // Start Stimulus application
    application = Application.start()
    application.register("clipboard", ClipboardController)
  })

  describe("with basic structure", () => {
    beforeEach(() => {
      document.body.innerHTML = `
        <div data-controller="clipboard">
          <input data-clipboard-target="source" value="text to copy" />
          <button data-clipboard-target="button" data-action="click->clipboard#copy">Copy</button>
          <span data-clipboard-target="successMessage" style="display: none;">Copied!</span>
        </div>
      `
    })

    it("copies text to clipboard when copy is called", async () => {
      const button = document.querySelector(
        "[data-clipboard-target='button']",
      ) as HTMLButtonElement
      button.click()

      expect(navigator.clipboard.writeText).toHaveBeenCalledWith("text to copy")
    })

    it("shows success message and hides button after copy", async () => {
      const button = document.querySelector(
        "[data-clipboard-target='button']",
      ) as HTMLElement
      const successMessage = document.querySelector(
        "[data-clipboard-target='successMessage']",
      ) as HTMLElement

      button.click()

      // Wait for clipboard promise to resolve
      await vi.waitFor(() => {
        expect(button.style.display).toBe("none")
        expect(successMessage.style.display).toBe("inline")
      })
    })
  })

  describe("with button wrapper structure (Pulse copy button)", () => {
    beforeEach(() => {
      // This matches the new _copy_to_clipboard.html.erb structure
      document.body.innerHTML = `
        <button type="button" class="pulse-copy-btn pulse-action-btn-secondary"
                data-controller="clipboard" data-action="click->clipboard#copy">
          <input type="text" value="https://example.com/invite" data-clipboard-target="source" style="display:none;"/>
          <span class="pulse-copy-btn-content" data-clipboard-target="button">
            <svg class="octicon"><!-- copy icon --></svg>
            <span>Copy link to clipboard</span>
          </span>
          <span class="pulse-copy-btn-content" data-clipboard-target="successMessage" style="display:none;">
            <svg class="octicon"><!-- check icon --></svg>
            <span>Copied!</span>
          </span>
        </button>
      `
    })

    it("copies text from hidden input to clipboard", async () => {
      const button = document.querySelector("button") as HTMLButtonElement
      button.click()

      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
        "https://example.com/invite",
      )
    })

    it("shows success message and hides copy text after copy", async () => {
      const button = document.querySelector("button") as HTMLButtonElement
      const copyContent = document.querySelector(
        "[data-clipboard-target='button']",
      ) as HTMLElement
      const successContent = document.querySelector(
        "[data-clipboard-target='successMessage']",
      ) as HTMLElement

      button.click()

      await vi.waitFor(() => {
        expect(copyContent.style.display).toBe("none")
        expect(successContent.style.display).toBe("inline")
      })
    })

    it("returns to copy state after timeout", async () => {
      vi.useFakeTimers()

      const button = document.querySelector("button") as HTMLButtonElement
      const copyContent = document.querySelector(
        "[data-clipboard-target='button']",
      ) as HTMLElement
      const successContent = document.querySelector(
        "[data-clipboard-target='successMessage']",
      ) as HTMLElement

      button.click()

      // Wait for clipboard promise
      await vi.runAllTimersAsync()

      // Fast-forward past the 2 second timeout
      await vi.advanceTimersByTimeAsync(2000)

      expect(copyContent.style.display).toBe("inline")
      expect(successContent.style.display).toBe("none")

      vi.useRealTimers()
    })
  })
})
