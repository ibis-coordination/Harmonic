import { Controller } from "@hotwired/stimulus"

export default class FormTrackerController extends Controller {
  static targets = ["submit"]

  declare readonly submitTarget: HTMLButtonElement
  declare readonly hasSubmitTarget: boolean

  private initialState: Map<string, string> = new Map()

  connect(): void {
    this.captureInitialState()
    this.updateSubmitState()
  }

  captureInitialState(): void {
    const form = this.element as HTMLFormElement
    this.initialState = this.getFormState(form)
  }

  trackChange(): void {
    this.updateSubmitState()
  }

  updateSubmitState(): void {
    if (!this.hasSubmitTarget) return

    const hasChanges = this.hasFormChanges()
    this.submitTarget.disabled = !hasChanges

    if (hasChanges) {
      this.submitTarget.classList.remove("pulse-action-btn-disabled")
    } else {
      this.submitTarget.classList.add("pulse-action-btn-disabled")
    }
  }

  hasFormChanges(): boolean {
    const form = this.element as HTMLFormElement
    const currentState = this.getFormState(form)

    // Check if any values changed
    for (const [key, value] of currentState.entries()) {
      if (this.initialState.get(key) !== value) {
        return true
      }
    }

    // Check if any initial keys are missing
    for (const [key] of this.initialState.entries()) {
      if (!currentState.has(key)) {
        return true
      }
    }

    // Check if any new keys were added
    for (const [key] of currentState.entries()) {
      if (!this.initialState.has(key)) {
        return true
      }
    }

    return false
  }

  // Build a Map from FormData, keeping the last value for duplicate keys
  // This handles Rails checkbox pattern (hidden field + checkbox with same name)
  private getFormState(form: HTMLFormElement): Map<string, string> {
    const formData = new FormData(form)
    const state = new Map<string, string>()
    for (const [key, value] of formData.entries()) {
      if (typeof value === "string") {
        state.set(key, value)
      }
    }
    return state
  }
}
