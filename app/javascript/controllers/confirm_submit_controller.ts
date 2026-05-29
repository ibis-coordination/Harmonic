import { Controller } from "@hotwired/stimulus"

// Shows a native confirm() dialog and preventDefaults the triggering event
// if the user clicks Cancel. CSP-safe replacement for the
// `onclick="return confirm('…')"` and `onsubmit="return confirm('…')"`
// patterns. (data-turbo-confirm would also work, but this app doesn't
// import Turbo — only Stimulus.)
//
// On a button:
//   <button type="submit"
//           data-controller="confirm-submit"
//           data-confirm-submit-message-value="Delete forever?"
//           data-action="click->confirm-submit#prompt">Delete</button>
//
// On a form:
//   <form action="/x" method="post"
//         data-controller="confirm-submit"
//         data-confirm-submit-message-value="Delete forever?"
//         data-action="submit->confirm-submit#prompt">…</form>
export default class extends Controller {
  static values = { message: String }
  declare readonly messageValue: string

  prompt(event: Event): void {
    if (!window.confirm(this.messageValue)) {
      event.preventDefault()
    }
  }
}
