import { Controller } from "@hotwired/stimulus"

// Toggle CSS line-clamp on a feed-item card body. The server renders the full
// markdown HTML inside the body target with the `-clamped` class applied; we
// detect on connect whether the content actually overflows the clamp, and only
// then unhide the "Show more" button. Clicking the button removes the clamp
// class (and swaps text); clicking again puts it back.
//
// Markup:
//   <div data-controller="card-expand" class="pulse-feed-item-content">
//     <div data-card-expand-target="body" class="pulse-feed-item-content-clamped">
//       <%= full rendered markdown %>
//     </div>
//     <button data-card-expand-target="toggle"
//             data-action="click->card-expand#toggle"
//             data-no-navigate hidden>Show more</button>
//   </div>
//
// `data-no-navigate` keeps the card-navigate controller (whole-card click =
// navigate to show page) from also firing when the user clicks the button.
const CLAMP_CLASS = "pulse-feed-item-content-clamped"
const EXPAND_LABEL = "Show more"
const COLLAPSE_LABEL = "Show less"

export default class extends Controller {
  static targets = ["body", "toggle"]

  declare readonly bodyTarget: HTMLElement
  declare readonly toggleTarget: HTMLButtonElement
  declare readonly hasBodyTarget: boolean
  declare readonly hasToggleTarget: boolean

  connect(): void {
    if (!this.hasBodyTarget || !this.hasToggleTarget) return
    // scrollHeight > clientHeight means the clamp is actually hiding content.
    // If the body fits inside the clamp, leave the button hidden — no Show
    // more affordance when there's nothing more to show.
    if (this.bodyTarget.scrollHeight > this.bodyTarget.clientHeight) {
      this.toggleTarget.hidden = false
    }
  }

  toggle(event: Event): void {
    event.preventDefault()
    event.stopPropagation()
    const clamped = this.bodyTarget.classList.toggle(CLAMP_CLASS)
    this.toggleTarget.textContent = clamped ? EXPAND_LABEL : COLLAPSE_LABEL
    this.toggleTarget.setAttribute("aria-expanded", clamped ? "false" : "true")
  }
}
