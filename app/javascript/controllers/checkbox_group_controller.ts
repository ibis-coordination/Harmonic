import { Controller } from "@hotwired/stimulus"

export default class CheckboxGroupController extends Controller {
  static targets = ["checkbox"]

  declare readonly checkboxTargets: HTMLInputElement[]

  checkAll(event: Event): void {
    event.preventDefault()
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = true
    })
  }

  uncheckAll(event: Event): void {
    event.preventDefault()
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = false
    })
  }
}
