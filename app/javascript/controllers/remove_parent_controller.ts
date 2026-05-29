import { Controller } from "@hotwired/stimulus"

// Removes the controller element's parent from the DOM on `remove` action.
// CSP-safe replacement for the inline `onclick="this.parentElement.remove()"`
// pattern used by flash-message dismiss buttons (and reusable for any
// "× dismisses its container" affordance).
//
//   <div class="pulse-notice">
//     <span>Saved!</span>
//     <button type="button" class="pulse-dismiss-btn"
//             data-controller="remove-parent"
//             data-action="click->remove-parent#remove">&times;</button>
//   </div>
export default class extends Controller {
  remove(): void {
    this.element.parentElement?.remove()
  }
}
