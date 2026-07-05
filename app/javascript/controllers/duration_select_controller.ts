import { Controller } from "@hotwired/stimulus"

// Duration select with a "Custom end time" escape hatch (empty option value).
// Preset durations let the server derive ends_at from starts_at +
// duration_minutes; picking the custom option reveals an explicit ends_at
// datetime input, which the server uses when duration_minutes is blank.
// This is what makes multi-day events creatable from the form.
export default class DurationSelectController extends Controller {
  static targets = ["select", "customFields"]

  declare readonly selectTarget: HTMLSelectElement
  declare readonly customFieldsTarget: HTMLElement

  connect(): void {
    this.toggle()
  }

  toggle(): void {
    const custom = this.selectTarget.value === ""
    this.customFieldsTarget.style.display = custom ? "" : "none"
  }
}
