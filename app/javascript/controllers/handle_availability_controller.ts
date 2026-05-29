import { Controller } from "@hotwired/stimulus"

// Live handle-availability check for the New Collective form. Strips
// disallowed characters from the input on every keystroke; for valid
// handles, fetches an availability endpoint and updates a preview span
// (with strikethrough on taken) plus an error message.
//
// Markup:
//   <div data-controller="handle-availability"
//        data-handle-availability-check-url-value="/collectives/available">
//     <span data-handle-availability-target="example">handle</span>
//     <span data-handle-availability-target="error" style="display:none;">…</span>
//     <input data-handle-availability-target="input"
//            data-action="input->handle-availability#check">
//   </div>
const VALID_HANDLE = /^[a-z0-9-]+$/
const INVALID_CHARS = /[^a-z0-9-]/g

export default class extends Controller {
  static targets = ["input", "example", "error"]
  static values = { checkUrl: String }

  declare readonly inputTarget: HTMLInputElement
  declare readonly exampleTarget: HTMLElement
  declare readonly errorTarget: HTMLElement
  declare readonly checkUrlValue: string

  check(): void {
    const handle = this.inputTarget.value
    if (!VALID_HANDLE.test(handle)) {
      // Strip disallowed characters in place so the field self-corrects as
      // the user types. Don't fire a fetch for the partial value.
      this.inputTarget.value = handle.replace(INVALID_CHARS, "")
      return
    }
    void this.checkAvailability(handle)
  }

  private async checkAvailability(handle: string): Promise<void> {
    const url = `${this.checkUrlValue}?handle=${encodeURIComponent(handle)}`
    const response = await fetch(url)
    const data = (await response.json()) as { available: boolean }
    // Race guard: an earlier-typed handle's fetch may resolve after a later
    // one. Only apply if the input still matches what we asked about.
    if (this.inputTarget.value !== handle) return

    this.exampleTarget.textContent = handle
    if (data.available) {
      this.exampleTarget.style.textDecoration = "none"
      this.errorTarget.style.display = "none"
      this.inputTarget.classList.remove("pulse-form-input-error")
    } else {
      this.exampleTarget.style.textDecoration = "line-through"
      this.errorTarget.style.display = "block"
      this.inputTarget.classList.add("pulse-form-input-error")
    }
  }
}
