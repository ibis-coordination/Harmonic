import { Controller } from "@hotwired/stimulus"

// Toggles a table-note row between its read-only display and an inline edit
// form (issue #286). Each editable <tr> has this controller. The row's cell
// inputs are associated (via the HTML `form=` attribute) with a hidden
// update_row form rendered after the table, so pressing Save submits that
// form through Turbo — no fetch needed. Cancel restores the original values.
export default class extends Controller {
  static targets = [
    "display",
    "input",
    "editButton",
    "saveButton",
    "cancelButton",
    "deleteButton",
  ]

  declare readonly displayTargets: HTMLElement[]
  declare readonly inputTargets: HTMLInputElement[]
  declare readonly editButtonTargets: HTMLElement[]
  declare readonly saveButtonTargets: HTMLElement[]
  declare readonly cancelButtonTargets: HTMLElement[]
  declare readonly deleteButtonTargets: HTMLElement[]

  edit(): void {
    this.setEditing(true)
    this.inputTargets[0]?.focus()
  }

  cancel(): void {
    // Discard edits — reset each input to its server-rendered value.
    this.inputTargets.forEach((input) => {
      input.value = input.defaultValue
    })
    this.setEditing(false)
  }

  private setEditing(editing: boolean): void {
    this.displayTargets.forEach((el) => (el.hidden = editing))
    this.inputTargets.forEach((el) => (el.hidden = !editing))
    this.editButtonTargets.forEach((el) => (el.hidden = editing))
    this.deleteButtonTargets.forEach((el) => (el.hidden = editing))
    this.saveButtonTargets.forEach((el) => (el.hidden = !editing))
    this.cancelButtonTargets.forEach((el) => (el.hidden = !editing))
  }
}
