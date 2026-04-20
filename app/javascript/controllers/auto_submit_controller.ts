import { Controller } from "@hotwired/stimulus"

// Automatically submits a form on connect. Used by the reverification
// replay flow to re-submit the original request after TOTP verification.
export default class extends Controller {
  connect() {
    // Defer to next frame to ensure the browser has processed the
    // response cookies (session) before submitting the form.
    requestAnimationFrame(() => {
      (this.element as HTMLFormElement).requestSubmit()
    })
  }
}
