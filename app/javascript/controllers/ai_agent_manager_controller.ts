import { Controller } from "@hotwired/stimulus"

export default class AiAgentManagerController extends Controller {
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

    const ai_agentId = this.selectTarget.value
    if (!ai_agentId) return

    const url = this.addFormTarget.action

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ ai_agent_id: ai_agentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to add ai_agent")
      })
      .then((data: { ai_agent_id: string; ai_agent_name: string; ai_agent_path: string; parent_name: string; parent_path: string }) => {
        // Add row to the table
        this.addRowToTable(data)
        // Remove option from select
        this.removeOptionFromSelect(ai_agentId)
      })
      .catch((error) => {
        console.error("Error adding ai_agent:", error)
        alert("Failed to add ai_agent")
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const ai_agentId = button.dataset.ai_agentId
    const ai_agentName = button.dataset.ai_agentName || "this ai_agent"
    const url = button.dataset.removeUrl

    if (!ai_agentId || !url) return

    if (!confirm(`Remove ${ai_agentName} from this studio?`)) return

    fetch(url, {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ ai_agent_id: ai_agentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to remove ai_agent")
      })
      .then((data: { ai_agent_id: string; ai_agent_name: string; can_readd: boolean }) => {
        // Remove row from table
        this.removeRowFromTable(ai_agentId)
        // If can_readd, add option back to select
        if (data.can_readd && this.hasSelectTarget) {
          this.addOptionToSelect(data.ai_agent_id, data.ai_agent_name)
        }
      })
      .catch((error) => {
        console.error("Error removing ai_agent:", error)
        alert("Failed to remove ai_agent")
      })
  }

  private addRowToTable(data: { ai_agent_id: string; ai_agent_name: string; ai_agent_path: string; parent_name: string; parent_path: string }): void {
    const tbody = this.listTarget.querySelector("tbody")
    if (!tbody) return

    const emptyMessage = this.listTarget.querySelector(".empty-message")
    if (emptyMessage) emptyMessage.remove()

    // Show table if it was hidden
    const table = this.listTarget.querySelector("table")
    if (table) table.style.display = ""

    const row = document.createElement("tr")
    row.dataset.ai_agentId = data.ai_agent_id
    row.innerHTML = `
      <td><a href="${data.ai_agent_path}">${data.ai_agent_name}</a></td>
      <td><a href="${data.parent_path}">${data.parent_name}</a></td>
      <td>
        <button type="button" class="button-small button-danger"
                data-action="ai_agent-manager#remove"
                data-ai_agent-id="${data.ai_agent_id}"
                data-ai_agent-name="${data.ai_agent_name}"
                data-remove-url="${this.removeUrlValue}">
          Remove
        </button>
      </td>
    `
    tbody.appendChild(row)
  }

  private removeRowFromTable(ai_agentId: string): void {
    const row = this.listTarget.querySelector(`tr[data-ai_agent-id="${ai_agentId}"]`)
    if (row) row.remove()

    // Check if table is now empty
    const tbody = this.listTarget.querySelector("tbody")
    if (tbody && tbody.children.length === 0) {
      const table = this.listTarget.querySelector("table")
      if (table) table.style.display = "none"

      const emptyP = document.createElement("p")
      emptyP.className = "empty-message"
      emptyP.innerHTML = "<em>No ai_agents in this studio.</em>"
      this.listTarget.appendChild(emptyP)
    }
  }

  private removeOptionFromSelect(ai_agentId: string): void {
    if (!this.hasSelectTarget) return
    const option = this.selectTarget.querySelector(`option[value="${ai_agentId}"]`)
    if (option) option.remove()
    // Reset select to prompt
    this.selectTarget.value = ""
  }

  private addOptionToSelect(ai_agentId: string, ai_agentName: string): void {
    if (!this.hasSelectTarget) return
    const option = document.createElement("option")
    option.value = ai_agentId
    option.text = ai_agentName
    this.selectTarget.appendChild(option)
  }
}
