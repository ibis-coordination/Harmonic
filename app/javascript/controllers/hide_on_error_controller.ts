import { Controller } from "@hotwired/stimulus"

// Hides its element when the `error` event fires on it. Used as a CSP-safe
// replacement for the `onerror="this.style.display='none'"` inline handler
// on <img> avatar fallbacks: when the image src fails to load, the img
// hides itself and the initials span underneath shows through.
//
//   <img src="..." class="pulse-avatar-img"
//        data-controller="hide-on-error"
//        data-action="error->hide-on-error#hide">
export default class extends Controller {
  hide(): void {
    ;(this.element as HTMLElement).style.display = "none"
  }
}
