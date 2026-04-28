import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textFields", "tableFields", "subtypeInput", "textBtn", "tableBtn"]

  declare textFieldsTarget: HTMLElement
  declare tableFieldsTarget: HTMLElement
  declare subtypeInputTarget: HTMLInputElement
  declare textBtnTarget: HTMLElement
  declare tableBtnTarget: HTMLElement

  connect() {
    this.toggle()
  }

  toggle() {
    const isTable = this.subtypeInputTarget.value === "table"
    this.textFieldsTarget.style.display = isTable ? "none" : ""
    this.tableFieldsTarget.style.display = isTable ? "" : "none"
    this.textBtnTarget.className = isTable ? "pulse-action-btn-secondary" : "pulse-action-btn"
    this.tableBtnTarget.className = isTable ? "pulse-action-btn" : "pulse-action-btn-secondary"
  }

  selectText() {
    this.subtypeInputTarget.value = "text"
    this.toggle()
  }

  selectTable() {
    this.subtypeInputTarget.value = "table"
    this.toggle()
  }

  addColumn() {
    const container = this.tableFieldsTarget.querySelector("[data-columns]")
    if (!container) return

    const index = Date.now()
    const row = document.createElement("div")
    row.style.cssText = "display: flex; gap: 8px; margin-bottom: 8px;"
    row.innerHTML = `
      <input type="text" name="columns[${index}][name]" placeholder="Column name" class="pulse-form-input" style="flex: 2;" required>
      <select name="columns[${index}][type]" class="pulse-form-input" style="flex: 1;">
        <option value="text">Text</option>
        <option value="number">Number</option>
        <option value="boolean">Boolean</option>
        <option value="date">Date</option>
      </select>
      <button type="button" class="pulse-action-btn-secondary" style="padding: 4px 8px;" data-action="note-subtype#removeColumn">✕</button>
    `
    container.appendChild(row)
  }

  removeColumn(event: Event) {
    const button = event.currentTarget as HTMLElement
    button.closest("[data-columns] > div")?.remove()
  }
}
