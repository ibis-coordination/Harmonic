import { Controller } from "@hotwired/stimulus"

// CSP-safe replacement for `href="javascript:history.back()"` links.
// Wire on an <a> (or <button>) with a sensible fallback href for users
// without JS / pre-Stimulus:
//
//   <a href="/somewhere" class="pulse-btn"
//      data-controller="history-back"
//      data-action="click->history-back#back">Cancel</a>
//
// Optionally configure a "revealed" class to keep the control hidden until
// there is in-app history to return to. Used by the mobile header back button
// (#322), which has nothing to go back to on a fresh PWA launch:
//
//   <button class="pulse-back-btn"
//           data-controller="history-back"
//           data-history-back-revealed-class="pulse-back-btn--visible"
//           data-action="click->history-back#back">…</button>
//
// The element's own CSS hides it by default; the class is only added when
// window.history has an earlier entry, so no-JS users never see a dead button.
export default class extends Controller<HTMLElement> {
  static classes = ["revealed"]

  declare readonly revealedClass: string
  declare readonly hasRevealedClass: boolean

  connect(): void {
    if (this.hasRevealedClass && this.canGoBack()) {
      this.element.classList.add(this.revealedClass)
    }
  }

  back(event: Event): void {
    event.preventDefault()
    window.history.back()
  }

  private canGoBack(): boolean {
    return window.history.length > 1
  }
}
