import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

export default class AiAgentSuperagentAdderController extends Controller {
  static targets = ["form", "select", "superagentList"]
  static values = { removeUrl: String }

  declare readonly formTarget: HTMLFormElement
  declare readonly selectTarget: HTMLSelectElement
  declare readonly superagentListTarget: HTMLElement
  declare readonly hasSelectTarget: boolean
  declare readonly hasFormTarget: boolean
  declare readonly removeUrlValue: string

  add(event: Event): void {
    event.preventDefault()

    if (!this.hasSelectTarget) return

    const superagentId = this.selectTarget.value
    if (!superagentId) return

    const url = this.formTarget.action

    fetchWithCsrf(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
      },
      body: JSON.stringify({ superagent_id: superagentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to add to studio")
      })
      .then((data: { superagent_id: number; superagent_name: string; superagent_path: string }) => {
        // Add studio to the list
        this.addSuperagentToList(data)
        // Remove option from select
        this.removeOptionFromSelect(String(data.superagent_id))
      })
      .catch((error) => {
        console.error("Error adding to studio:", error)
        alert("Failed to add to studio")
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const superagentId = button.dataset.superagentId
    const superagentName = button.dataset.superagentName || "this studio"
    const url = this.removeUrlValue

    if (!superagentId || !url) return

    if (!confirm(`Remove this ai_agent from ${superagentName}?`)) return

    fetchWithCsrf(url, {
      method: "DELETE",
      headers: {
        Accept: "application/json",
      },
      body: JSON.stringify({ superagent_id: superagentId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to remove from studio")
      })
      .then((data: { superagent_id: number; superagent_name: string }) => {
        // Remove studio from list
        this.removeSuperagentFromList(String(data.superagent_id))
        // Add option back to select if it exists
        if (this.hasSelectTarget) {
          this.addOptionToSelect(String(data.superagent_id), data.superagent_name)
        }
      })
      .catch((error) => {
        console.error("Error removing from studio:", error)
        alert("Failed to remove from studio")
      })
  }

  private addSuperagentToList(data: { superagent_id: number; superagent_name: string; superagent_path: string }): void {
    // Remove "None" message if present
    const noneMessage = this.superagentListTarget.querySelector(".none-message")
    if (noneMessage) noneMessage.remove()

    // Create new studio item as <li>
    const item = document.createElement("li")
    item.className = "studio-item"
    item.dataset.superagentId = String(data.superagent_id)
    item.innerHTML = `<a href="${data.superagent_path}">${data.superagent_name}</a> <button type="button" class="button-small button-danger" data-action="ai_agent-superagent-adder#remove" data-superagent-id="${data.superagent_id}" data-superagent-name="${data.superagent_name}">Remove from studio</button>`

    // Add to the list
    this.superagentListTarget.appendChild(item)
  }

  private removeSuperagentFromList(superagentId: string): void {
    const item = this.superagentListTarget.querySelector(`.studio-item[data-superagent-id="${superagentId}"]`)
    if (item) {
      item.remove()
    }

    // Show "None" if no studios left
    const remainingItems = this.superagentListTarget.querySelectorAll(".studio-item")
    if (remainingItems.length === 0) {
      const noneMessage = document.createElement("li")
      noneMessage.className = "none-message"
      noneMessage.innerHTML = "<em>Not a member of any studios</em>"
      this.superagentListTarget.appendChild(noneMessage)
    }

    // Show the form if it was hidden
    if (this.hasFormTarget) {
      this.formTarget.style.display = ""
    }
  }

  private removeOptionFromSelect(superagentId: string): void {
    if (!this.hasSelectTarget) return
    const option = this.selectTarget.querySelector(`option[value="${superagentId}"]`)
    if (option) option.remove()
    this.selectTarget.value = ""

    // Hide the form if no more options
    if (this.selectTarget.options.length <= 1 && this.hasFormTarget) {
      this.formTarget.style.display = "none"
    }
  }

  private addOptionToSelect(superagentId: string, superagentName: string): void {
    if (!this.hasSelectTarget) return
    const option = document.createElement("option")
    option.value = superagentId
    option.text = superagentName
    this.selectTarget.appendChild(option)
  }
}
