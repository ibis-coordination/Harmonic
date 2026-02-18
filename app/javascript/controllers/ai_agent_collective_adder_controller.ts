import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

export default class AiAgentCollectiveAdderController extends Controller {
  static targets = ["form", "select", "collectiveList"]
  static values = { removeUrl: String }

  declare readonly formTarget: HTMLFormElement
  declare readonly selectTarget: HTMLSelectElement
  declare readonly collectiveListTarget: HTMLElement
  declare readonly hasSelectTarget: boolean
  declare readonly hasFormTarget: boolean
  declare readonly removeUrlValue: string

  add(event: Event): void {
    event.preventDefault()

    if (!this.hasSelectTarget) return

    const collectiveId = this.selectTarget.value
    if (!collectiveId) return

    const url = this.formTarget.action

    fetchWithCsrf(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
      },
      body: JSON.stringify({ collective_id: collectiveId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to add to studio")
      })
      .then((data: { collective_id: number; collective_name: string; collective_path: string }) => {
        // Add studio to the list
        this.addCollectiveToList(data)
        // Remove option from select
        this.removeOptionFromSelect(String(data.collective_id))
      })
      .catch((error) => {
        console.error("Error adding to studio:", error)
        alert("Failed to add to studio")
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const collectiveId = button.dataset.collectiveId
    const collectiveName = button.dataset.collectiveName || "this studio"
    const url = this.removeUrlValue

    if (!collectiveId || !url) return

    if (!confirm(`Remove this ai_agent from ${collectiveName}?`)) return

    fetchWithCsrf(url, {
      method: "DELETE",
      headers: {
        Accept: "application/json",
      },
      body: JSON.stringify({ collective_id: collectiveId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to remove from studio")
      })
      .then((data: { collective_id: number; collective_name: string }) => {
        // Remove studio from list
        this.removeCollectiveFromList(String(data.collective_id))
        // Add option back to select if it exists
        if (this.hasSelectTarget) {
          this.addOptionToSelect(String(data.collective_id), data.collective_name)
        }
      })
      .catch((error) => {
        console.error("Error removing from studio:", error)
        alert("Failed to remove from studio")
      })
  }

  private addCollectiveToList(data: { collective_id: number; collective_name: string; collective_path: string }): void {
    // Remove "None" message if present
    const noneMessage = this.collectiveListTarget.querySelector(".none-message")
    if (noneMessage) noneMessage.remove()

    // Create new studio item as <li>
    const item = document.createElement("li")
    item.className = "studio-item"
    item.dataset.collectiveId = String(data.collective_id)
    item.innerHTML = `<a href="${data.collective_path}">${data.collective_name}</a> <button type="button" class="button-small button-danger" data-action="ai_agent-collective-adder#remove" data-collective-id="${data.collective_id}" data-collective-name="${data.collective_name}">Remove from studio</button>`

    // Add to the list
    this.collectiveListTarget.appendChild(item)
  }

  private removeCollectiveFromList(collectiveId: string): void {
    const item = this.collectiveListTarget.querySelector(`.studio-item[data-collective-id="${collectiveId}"]`)
    if (item) {
      item.remove()
    }

    // Show "None" if no studios left
    const remainingItems = this.collectiveListTarget.querySelectorAll(".studio-item")
    if (remainingItems.length === 0) {
      const noneMessage = document.createElement("li")
      noneMessage.className = "none-message"
      noneMessage.innerHTML = "<em>Not a member of any studios</em>"
      this.collectiveListTarget.appendChild(noneMessage)
    }

    // Show the form if it was hidden
    if (this.hasFormTarget) {
      this.formTarget.style.display = ""
    }
  }

  private removeOptionFromSelect(collectiveId: string): void {
    if (!this.hasSelectTarget) return
    const option = this.selectTarget.querySelector(`option[value="${collectiveId}"]`)
    if (option) option.remove()
    this.selectTarget.value = ""

    // Hide the form if no more options
    if (this.selectTarget.options.length <= 1 && this.hasFormTarget) {
      this.formTarget.style.display = "none"
    }
  }

  private addOptionToSelect(collectiveId: string, collectiveName: string): void {
    if (!this.hasSelectTarget) return
    const option = document.createElement("option")
    option.value = collectiveId
    option.text = collectiveName
    this.selectTarget.appendChild(option)
  }
}
