import { Controller } from "@hotwired/stimulus"

export default class SubagentManagerController extends Controller {
  static targets = ["list", "addForm", "select"]
  static values = { removeUrl: String }

  declare readonly listTarget: HTMLElement
  declare readonly addFormTarget: HTMLFormElement
  declare readonly selectTarget: HTMLSelectElement
  declare readonly hasSelectTarget: boolean
  declare readonly removeUrlValue: string

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  add(event: Event): void {
    event.preventDefault()

    if (!this.hasSelectTarget) return

    const subagentId = this.selectTarget.value
    if (!subagentId) return

    const url = this.addFormTarget.action

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ subagent_id: subagentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to add subagent")
      })
      .then((data: { subagent_id: string; subagent_name: string; subagent_path: string; parent_name: string; parent_path: string }) => {
        // Add row to the table
        this.addRowToTable(data)
        // Remove option from select
        this.removeOptionFromSelect(subagentId)
      })
      .catch((error) => {
        console.error("Error adding subagent:", error)
        alert("Failed to add subagent")
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const subagentId = button.dataset.subagentId
    const subagentName = button.dataset.subagentName || "this subagent"
    const url = button.dataset.removeUrl

    if (!subagentId || !url) return

    if (!confirm(`Remove ${subagentName} from this studio?`)) return

    fetch(url, {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ subagent_id: subagentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to remove subagent")
      })
      .then((data: { subagent_id: string; subagent_name: string; can_readd: boolean }) => {
        // Remove row from table
        this.removeRowFromTable(subagentId)
        // If can_readd, add option back to select
        if (data.can_readd && this.hasSelectTarget) {
          this.addOptionToSelect(data.subagent_id, data.subagent_name)
        }
      })
      .catch((error) => {
        console.error("Error removing subagent:", error)
        alert("Failed to remove subagent")
      })
  }

  private addRowToTable(data: { subagent_id: string; subagent_name: string; subagent_path: string; parent_name: string; parent_path: string }): void {
    const tbody = this.listTarget.querySelector("tbody")
    if (!tbody) return

    const emptyMessage = this.listTarget.querySelector(".empty-message")
    if (emptyMessage) emptyMessage.remove()

    // Show table if it was hidden
    const table = this.listTarget.querySelector("table")
    if (table) table.style.display = ""

    const row = document.createElement("tr")
    row.dataset.subagentId = data.subagent_id
    row.innerHTML = `
      <td><a href="${data.subagent_path}">${data.subagent_name}</a></td>
      <td><a href="${data.parent_path}">${data.parent_name}</a></td>
      <td>
        <button type="button" class="button-small button-danger"
                data-action="subagent-manager#remove"
                data-subagent-id="${data.subagent_id}"
                data-subagent-name="${data.subagent_name}"
                data-remove-url="${this.removeUrlValue}">
          Remove
        </button>
      </td>
    `
    tbody.appendChild(row)
  }

  private removeRowFromTable(subagentId: string): void {
    const row = this.listTarget.querySelector(`tr[data-subagent-id="${subagentId}"]`)
    if (row) row.remove()

    // Check if table is now empty
    const tbody = this.listTarget.querySelector("tbody")
    if (tbody && tbody.children.length === 0) {
      const table = this.listTarget.querySelector("table")
      if (table) table.style.display = "none"

      const emptyP = document.createElement("p")
      emptyP.className = "empty-message"
      emptyP.innerHTML = "<em>No subagents in this studio.</em>"
      this.listTarget.appendChild(emptyP)
    }
  }

  private removeOptionFromSelect(subagentId: string): void {
    if (!this.hasSelectTarget) return
    const option = this.selectTarget.querySelector(`option[value="${subagentId}"]`)
    if (option) option.remove()
    // Reset select to prompt
    this.selectTarget.value = ""
  }

  private addOptionToSelect(subagentId: string, subagentName: string): void {
    if (!this.hasSelectTarget) return
    const option = document.createElement("option")
    option.value = subagentId
    option.text = subagentName
    this.selectTarget.appendChild(option)
  }
}
