import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

/**
 * AjaxToggleController turns a plain <button> into a two-state toggle that
 * POSTs without a full page reload.
 *
 * On click it POSTs to the current `url` value. On a successful response it
 * swaps the button's innerHTML with `alt-html`, and swaps the `url` value
 * with `alt-url`. Clicking again POSTs to the new URL and swaps back.
 *
 * Usage:
 *
 *   <button data-controller="ajax-toggle"
 *           data-action="click->ajax-toggle#toggle"
 *           data-ajax-toggle-url-value="/u/dan/actions/add_to_list"
 *           data-ajax-toggle-alt-url-value="/u/dan/actions/remove_from_list"
 *           data-ajax-toggle-alt-html-value="<svg>...</svg> On your list">
 *     <svg>...</svg> Add to your list
 *   </button>
 *
 * On click the button visibly dims, POSTs, then either swaps to the alternate
 * state or restores itself on error.
 */
export default class AjaxToggleController extends Controller<HTMLButtonElement> {
  static values = {
    url: String,
    altUrl: String,
    altHtml: String,
  }

  declare urlValue: string
  declare altUrlValue: string
  declare altHtmlValue: string

  async toggle(event: Event): Promise<void> {
    event.preventDefault()
    if (this.element.disabled) return

    const previousHtml = this.element.innerHTML
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
    } catch {
      // Leave the button as-is; user can retry.
    } finally {
      this.element.disabled = false
      this.element.style.opacity = "1"
    }
  }
}
