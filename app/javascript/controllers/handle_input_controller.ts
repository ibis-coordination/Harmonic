import { Controller } from "@hotwired/stimulus"

// Filters a handle input as the user types: lowercase, whitespace becomes
// dashes, and characters outside [a-z0-9_-] are stripped. Mirrors the
// server-side normalization (TenantUser normalizes :handle), so what the
// user sees is what gets saved.
export default class HandleInputController extends Controller<HTMLInputElement> {
  sanitize(): void {
    const input = this.element
    const before = input.value
    const after = before
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9_-]/g, "")
    if (before === after) return

    const caret = input.selectionStart
    input.value = after
    if (caret !== null) {
      const position = Math.max(0, caret - (before.length - after.length))
      input.setSelectionRange(position, position)
    }
  }
}
