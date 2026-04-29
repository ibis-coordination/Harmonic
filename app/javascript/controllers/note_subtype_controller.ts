import { Controller } from "@hotwired/stimulus"
import { parseCsv } from "../utils/csv_parser"

export default class extends Controller {
  static targets = [
    "textFields",
    "reminderFields",
    "tableFields",
    "subtypeInput",
    "textBtn",
    "reminderBtn",
    "tableBtn",
    "manualColumnsSection",
    "csvImportSection",
    "manualColumnsBtn",
    "csvImportBtn",
    "csvInput",
    "fileInput",
    "csvPreview",
    "csvErrors",
    "initialRowsInput",
    "tableCreationModeInput",
  ]

  declare textFieldsTarget: HTMLElement
  declare reminderFieldsTarget: HTMLElement
  declare tableFieldsTarget: HTMLElement
  declare subtypeInputTarget: HTMLInputElement
  declare textBtnTarget: HTMLElement
  declare reminderBtnTarget: HTMLElement
  declare tableBtnTarget: HTMLElement

  declare hasReminderFieldsTarget: boolean
  declare hasReminderBtnTarget: boolean
  declare manualColumnsSectionTarget: HTMLElement
  declare csvImportSectionTarget: HTMLElement
  declare manualColumnsBtnTarget: HTMLElement
  declare csvImportBtnTarget: HTMLElement
  declare csvInputTarget: HTMLTextAreaElement
  declare fileInputTarget: HTMLInputElement
  declare csvPreviewTarget: HTMLElement
  declare csvErrorsTarget: HTMLElement
  declare initialRowsInputTarget: HTMLInputElement
  declare tableCreationModeInputTarget: HTMLInputElement

  declare hasManualColumnsSectionTarget: boolean
  declare hasCsvImportSectionTarget: boolean
  declare hasCsvInputTarget: boolean

  connect() {
    this.toggle()
  }

  // Text/Reminder/Table subtype toggle

  toggle() {
    const subtype = this.subtypeInputTarget.value

    this.textFieldsTarget.style.display = subtype === "text" ? "" : "none"
    if (this.hasReminderFieldsTarget) {
      this.reminderFieldsTarget.style.display = subtype === "reminder" ? "" : "none"
    }
    this.tableFieldsTarget.style.display = subtype === "table" ? "" : "none"

    // Disable inputs in hidden sections so they don't submit duplicate form values
    this.setInputsDisabled(this.textFieldsTarget, subtype !== "text")
    if (this.hasReminderFieldsTarget) {
      this.setInputsDisabled(this.reminderFieldsTarget, subtype !== "reminder")
    }

    this.textBtnTarget.className = subtype === "text" ? "pulse-action-btn" : "pulse-action-btn-secondary"
    if (this.hasReminderBtnTarget) {
      this.reminderBtnTarget.className = subtype === "reminder" ? "pulse-action-btn" : "pulse-action-btn-secondary"
    }
    this.tableBtnTarget.className = subtype === "table" ? "pulse-action-btn" : "pulse-action-btn-secondary"
  }

  private setInputsDisabled(container: HTMLElement, disabled: boolean) {
    container.querySelectorAll("textarea, input:not([type='hidden']), select").forEach((el) => {
      ;(el as HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement).disabled = disabled
    })
  }

  selectText() {
    this.subtypeInputTarget.value = "text"
    this.toggle()
  }

  selectReminder() {
    this.subtypeInputTarget.value = "reminder"
    this.toggle()
  }

  selectTable() {
    this.subtypeInputTarget.value = "table"
    this.toggle()
  }

  // Manual columns / CSV import toggle

  selectManualColumns() {
    if (!this.hasManualColumnsSectionTarget) return
    this.manualColumnsSectionTarget.style.display = ""
    this.csvImportSectionTarget.style.display = "none"
    this.manualColumnsBtnTarget.className = "pulse-action-btn"
    this.csvImportBtnTarget.className = "pulse-action-btn-secondary"
    this.tableCreationModeInputTarget.value = "manual"
    this.initialRowsInputTarget.value = ""
    // Clear CSV hidden columns so they don't submit
    const hiddenCols = this.csvImportSectionTarget.querySelector("[data-csv-columns]")
    if (hiddenCols) hiddenCols.innerHTML = ""
    // Re-enable manual column inputs
    this.manualColumnsSectionTarget.querySelectorAll("input, select").forEach((el) => {
      ;(el as HTMLInputElement).disabled = false
    })
  }

  selectCsvImport() {
    if (!this.hasCsvImportSectionTarget) return
    this.manualColumnsSectionTarget.style.display = "none"
    this.csvImportSectionTarget.style.display = ""
    this.manualColumnsBtnTarget.className = "pulse-action-btn-secondary"
    this.csvImportBtnTarget.className = "pulse-action-btn"
    this.tableCreationModeInputTarget.value = "csv"
    // Disable manual column inputs so they don't submit
    this.manualColumnsSectionTarget.querySelectorAll("input, select").forEach((el) => {
      ;(el as HTMLInputElement).disabled = true
    })
  }

  // Column management

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

  // CSV import

  parseCsvFromTextarea() {
    if (!this.hasCsvInputTarget) return
    this.parseCsvAndPreview(this.csvInputTarget.value)
  }

  async parseCsvFromFile() {
    const file = this.fileInputTarget.files?.[0]
    if (!file) return

    const text = await file.text()
    this.csvInputTarget.value = text
    this.parseCsvAndPreview(text)
  }

  private parseCsvAndPreview(csv: string) {
    const result = parseCsv(csv)

    // Show errors
    if (result.errors.length > 0) {
      this.csvErrorsTarget.innerHTML = result.errors
        .map((e) => `<p style="color: var(--color-danger-fg); font-size: 13px;">${this.escapeHtml(e)}</p>`)
        .join("")
    } else {
      this.csvErrorsTarget.innerHTML = ""
    }

    if (result.headers.length === 0) {
      this.csvPreviewTarget.innerHTML = ""
      this.initialRowsInputTarget.value = ""
      return
    }

    // Store columns as hidden fields so the form submits them
    // We create a hidden columns container inside the CSV section
    let hiddenCols = this.csvImportSectionTarget.querySelector("[data-csv-columns]") as HTMLElement
    if (!hiddenCols) {
      hiddenCols = document.createElement("div")
      hiddenCols.setAttribute("data-csv-columns", "")
      hiddenCols.style.display = "none"
      this.csvImportSectionTarget.appendChild(hiddenCols)
    }
    hiddenCols.innerHTML = result.headers
      .map(
        (h, i) =>
          `<input type="hidden" name="columns[csv${i}][name]" value="${this.escapeAttr(h)}">` +
          `<input type="hidden" name="columns[csv${i}][type]" value="text">`
      )
      .join("")

    // Store parsed rows
    this.initialRowsInputTarget.value = JSON.stringify(result.rows)

    // Show summary
    const colList = result.headers.map((h) => this.escapeHtml(h)).join(", ")
    this.csvPreviewTarget.innerHTML =
      `<p style="font-size: 13px; color: var(--color-fg-default); margin: 8px 0;">` +
      `<strong>${result.rows.length}</strong> rows, <strong>${result.headers.length}</strong> columns (${colList})` +
      `</p>`
  }

  private escapeHtml(str: string): string {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  private escapeAttr(str: string): string {
    return str.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
}
