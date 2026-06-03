import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

/**
 * AjaxToggleController turns a plain <button> into a two-state toggle that
 * POSTs without a full page reload.
 *
 * On click it POSTs to the current `url` value. On a successful response it
 * swaps the button's innerHTML with `alt-html`, the `url` with `alt-url`,
 * and (when set) the button's className with `alt-class`. Clicking again
 * POSTs to the new URL and swaps back.
 *
 * Usage:
 *
 *   <button class="pulse-action-btn"
 *           data-controller="ajax-toggle"
 *           data-action="click->ajax-toggle#toggle"
 *           data-ajax-toggle-url-value="/u/dan/actions/tune_in"
 *           data-ajax-toggle-alt-url-value="/u/dan/actions/tune_out"
 *           data-ajax-toggle-alt-html-value="<svg>...</svg> Tuned in"
 *           data-ajax-toggle-alt-class-value="pulse-action-btn-secondary">
 *     <svg>...</svg> Tune in
 *   </button>
 *
 * On click the button visibly dims, POSTs, then either swaps to the alternate
 * state or restores itself on error. `alt-class` is optional — empty string
 * means no class swap.
 */
export default class AjaxToggleController extends Controller<HTMLButtonElement> {
  static values = {
    url: String,
    altUrl: String,
    altHtml: String,
    altClass: String,
  }

  declare urlValue: string
  declare altUrlValue: string
  declare altHtmlValue: string
  declare altClassValue: string

  async toggle(event: Event): Promise<void> {
    event.preventDefault()
    if (this.element.disabled) return

    const previousHtml = this.element.innerHTML
    const previousClass = this.element.className
    this.element.disabled = true
    this.element.style.opacity = "0.5"

    try {
      const response = await fetchWithCsrf(this.urlValue, { method: "POST" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      // Successful POST — swap state.
      this.element.innerHTML = this.altHtmlValue
      this.altHtmlValue = previousHtml
      const previousUrl = this.urlValue
      this.urlValue = this.altUrlValue
      this.altUrlValue = previousUrl
      if (this.altClassValue) {
        this.element.className = this.altClassValue
        this.altClassValue = previousClass
      }
    } catch {
      // Leave the button as-is; user can retry.
    } finally {
      this.element.disabled = false
      this.element.style.opacity = "1"
    }
  }
}
