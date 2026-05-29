import { Controller } from "@hotwired/stimulus"

// Show/hide a section in response to a radio-group change. Wire on a
// container that holds both the radios and the section; the radios fire
// `change->radio-toggle#sync`. The section is shown unless the selected
// radio's value matches `data-radio-toggle-hide-on-value`.
//
// The initial state is left to the server-rendered `style="display:..."`
// — the controller does not force-set display until a radio change fires.
//
//   <section data-controller="radio-toggle"
//            data-radio-toggle-hide-on-value="all">
//     <input type="radio" name="x" value="all" checked
//            data-action="change->radio-toggle#sync">
//     <input type="radio" name="x" value="other"
//            data-action="change->radio-toggle#sync">
//     <div data-radio-toggle-target="section" style="display:none;">…</div>
//   </section>
export default class extends Controller {
  static targets = ["section"]
  static values = { hideOn: String }

  declare readonly sectionTarget: HTMLElement
  declare readonly hideOnValue: string

  connect(): void {
    // Reconcile section visibility with the currently-checked radio in case
    // a Turbo Drive cached snapshot restored a non-server-default selection
    // whose `display` didn't match.
    const checked = this.element.querySelector<HTMLInputElement>('input[type="radio"]:checked')
    if (!checked) return
    this.applyState(checked.value)
  }

  sync(event: Event): void {
    const radio = event.target as HTMLInputElement
    this.applyState(radio.value)
  }

  private applyState(value: string): void {
    this.sectionTarget.style.display = value === this.hideOnValue ? "none" : "block"
  }
}
