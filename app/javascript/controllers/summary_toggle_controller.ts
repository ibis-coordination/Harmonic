import { Controller } from "@hotwired/stimulus"

// Reveal the summary section (and its embed or form slot) on demand. The
// section + its slots start hidden so the parent resource page isn't
// dominated by summary content; kebab-menu items invoke `showEmbed` or
// `showForm` to surface the matching slot.
//
// Markup:
//   <span data-controller="note summary-toggle">
//     ...
//     <a data-action="click->summary-toggle#showEmbed">View summary</a>
//     <a data-action="click->summary-toggle#showForm">Add summary</a>
//     ...
//     <div data-summary-toggle-target="section" hidden>
//       <div data-summary-toggle-target="embed" hidden>...</div>
//       <div data-summary-toggle-target="form" hidden>...</div>
//     </div>
//   </span>
export default class extends Controller {
  static targets = ["section", "embed", "form"]

  declare readonly sectionTarget: HTMLElement
  declare readonly hasSectionTarget: boolean
  declare readonly embedTarget: HTMLElement
  declare readonly hasEmbedTarget: boolean
  declare readonly formTarget: HTMLElement
  declare readonly hasFormTarget: boolean

  showEmbed(event: Event): void {
    event.preventDefault()
    this.reveal(this.hasEmbedTarget ? this.embedTarget : null)
  }

  showForm(event: Event): void {
    event.preventDefault()
    this.reveal(this.hasFormTarget ? this.formTarget : null)
  }

  private reveal(slot: HTMLElement | null): void {
    if (this.hasSectionTarget) this.sectionTarget.hidden = false
    if (slot) slot.hidden = false
    if (this.hasSectionTarget) {
      this.sectionTarget.scrollIntoView({ behavior: "smooth", block: "start" })
    }
  }
}
