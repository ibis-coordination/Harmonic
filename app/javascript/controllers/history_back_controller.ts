import { Controller } from "@hotwired/stimulus"

// CSP-safe replacement for `href="javascript:history.back()"` links.
// Wire on an <a> (or <button>) with a sensible fallback href for users
// without JS / pre-Stimulus:
//
//   <a href="/somewhere" class="pulse-btn"
//      data-controller="history-back"
//      data-action="click->history-back#back">Cancel</a>
export default class extends Controller {
  back(event: Event): void {
    event.preventDefault()
    window.history.back()
  }
}
