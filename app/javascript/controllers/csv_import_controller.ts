import { Controller } from "@hotwired/stimulus"
import { parseCsv, type CsvParseResult } from "../utils/csv_parser"

export default class extends Controller {
  static targets = ["importSection", "csvInput", "fileInput", "preview", "errors", "submitBtn"]
  static values = { actionUrl: String, columns: Array }

  declare importSectionTarget: HTMLElement
  declare csvInputTarget: HTMLTextAreaElement
  declare fileInputTarget: HTMLInputElement
  declare previewTarget: HTMLElement
  declare errorsTarget: HTMLElement
  declare submitBtnTarget: HTMLButtonElement
  declare actionUrlValue: string
  declare columnsValue: string[]

  private parsedResult: CsvParseResult | null = null

  toggleImport() {
    const section = this.importSectionTarget
    section.style.display = section.style.display === "none" ? "" : "none"
  }

  parseFromTextarea() {
    const csv = this.csvInputTarget.value
    this.parseAndPreview(csv)
  }

  async parseFromFile() {
    const file = this.fileInputTarget.files?.[0]
    if (!file) return

    const text = await file.text()
    this.csvInputTarget.value = text
    this.parseAndPreview(text)
  }

  private parseAndPreview(csv: string) {
    const result = parseCsv(csv)
    this.parsedResult = result

    this.renderErrors(result.errors)

    if (result.rows.length === 0 && result.errors.length === 0) {
      this.previewTarget.innerHTML = '<p style="color: var(--color-fg-muted);">No data rows found.</p>'
      this.submitBtnTarget.style.display = "none"
      return
    }

    // Check for column mismatches if the table already has columns
    if (this.columnsValue.length > 0) {
      const warnings = [...result.errors]
      const missing = result.headers.filter((h) => !this.columnsValue.includes(h))
      const extra = this.columnsValue.filter((c) => !result.headers.includes(c))
      if (missing.length > 0) {
        warnings.push(`CSV has columns not in the table: ${missing.join(", ")}. These will be ignored.`)
      }
      if (extra.length > 0) {
        warnings.push(`Table has columns not in the CSV: ${extra.join(", ")}. These will be empty.`)
      }
      if (warnings.length > 0) {
        this.renderErrors(warnings)
      }
    }

    this.renderPreview(result)
    this.submitBtnTarget.style.display = ""
  }

  private renderErrors(errors: string[]) {
    if (errors.length === 0) {
      this.errorsTarget.innerHTML = ""
      return
    }
    this.errorsTarget.innerHTML = errors
      .map((e) => `<p style="color: var(--color-danger-fg); font-size: 13px;">${this.escapeHtml(e)}</p>`)
      .join("")
  }

  private renderPreview(result: CsvParseResult) {
    const maxPreviewRows = 5
    const headers = this.columnsValue.length > 0 ? this.columnsValue : result.headers
    const showRows = result.rows.slice(0, maxPreviewRows)

    let html = `<p style="font-size: 13px; color: var(--color-fg-muted); margin-bottom: 8px;">Preview (${showRows.length} of ${result.rows.length} rows):</p>`
    html += '<table class="pulse-table" style="font-size: 13px;"><thead><tr>'
    headers.forEach((h) => {
      html += `<th>${this.escapeHtml(h)}</th>`
    })
    html += "</tr></thead><tbody>"
    showRows.forEach((row) => {
      html += "<tr>"
      headers.forEach((h) => {
        html += `<td>${this.escapeHtml(row[h] || "")}</td>`
      })
      html += "</tr>"
    })
    if (result.rows.length > maxPreviewRows) {
      html += `<tr><td colspan="${headers.length}" style="text-align: center; color: var(--color-fg-muted);">... and ${result.rows.length - maxPreviewRows} more rows</td></tr>`
    }
    html += "</tbody></table>"

    this.previewTarget.innerHTML = html
  }

  async submitImport() {
    if (!this.parsedResult || this.parsedResult.rows.length === 0) return

    this.submitBtnTarget.disabled = true
    this.submitBtnTarget.textContent = "Importing..."

    const columns = this.columnsValue.length > 0 ? this.columnsValue : this.parsedResult.headers

    const operations = this.parsedResult.rows.map((row) => {
      const values: Record<string, string> = {}
      columns.forEach((col) => {
        if (row[col] !== undefined) values[col] = row[col]
      })
      return { action: "add_row", values }
    })

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""

      const response = await fetch(this.actionUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          Accept: "application/json",
        },
        body: JSON.stringify({ operations }),
      })

      if (response.ok) {
        window.location.reload()
      } else {
        const text = await response.text()
        this.renderErrors([`Import failed: ${text}`])
        this.submitBtnTarget.disabled = false
        this.submitBtnTarget.textContent = "Import Rows"
      }
    } catch (error) {
      this.renderErrors([`Import failed: ${error}`])
      this.submitBtnTarget.disabled = false
      this.submitBtnTarget.textContent = "Import Rows"
    }
  }

  private escapeHtml(str: string): string {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}
