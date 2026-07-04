import { Controller } from "@hotwired/stimulus"

/**
 * FeedBarInputController makes the feed bar's query textarea behave like a
 * wrapping text input: it grows to fit its content (a single-line <input>
 * hides long queries behind horizontal scroll), and Enter submits the form
 * instead of inserting a newline — queries have no meaningful line breaks.
 *
 * Usage:
 * <textarea rows="1" data-controller="feed-bar-input"
 *           data-action="input->feed-bar-input#resize keydown->feed-bar-input#keydown">
 */
export default class FeedBarInputController extends Controller<HTMLTextAreaElement> {
  connect(): void {
    // The prefilled query may already wrap; size to it on first paint.
    this.resize()
  }

  resize(): void {
    this.element.style.height = "auto"
    this.element.style.height = `${this.element.scrollHeight}px`
  }

  keydown(event: KeyboardEvent): void {
    if (event.key !== "Enter") return

    event.preventDefault()
    this.element.form?.requestSubmit()
  }
}
