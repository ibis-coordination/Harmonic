import { Controller } from "@hotwired/stimulus"

export default class CheckboxGroupController extends Controller {
  static targets = ["checkbox", "toggle"]

  declare readonly checkboxTargets: HTMLInputElement[]
  declare readonly hasToggleTarget: boolean
  declare readonly toggleTarget: HTMLInputElement

  connect(): void {
    this.syncToggle()
  }

  checkAll(event: Event): void {
    event.preventDefault()
    this.setAll(true)
  }

  uncheckAll(event: Event): void {
    event.preventDefault()
    this.setAll(false)
  }

  // A single "select all" checkbox drives the whole group.
  toggleAll(): void {
    if (!this.hasToggleTarget) return
    this.setAll(this.toggleTarget.checked)
  }

  // A member checkbox changed — reflect all/some/none on the toggle.
  syncToggle(): void {
    if (!this.hasToggleTarget) return
    const total = this.checkboxTargets.length
    const checked = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    this.toggleTarget.checked = total > 0 && checked === total
    this.toggleTarget.indeterminate = checked > 0 && checked < total
  }

  private setAll(checked: boolean): void {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checked
    })
    this.syncToggle()
  }
}
