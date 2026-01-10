import { Controller } from "@hotwired/stimulus"

export default class SubagentStudioAdderController extends Controller {
  static targets = ["form", "select", "studioList"]
  static values = { removeUrl: String }

  declare readonly formTarget: HTMLFormElement
  declare readonly selectTarget: HTMLSelectElement
  declare readonly studioListTarget: HTMLElement
  declare readonly hasSelectTarget: boolean
  declare readonly hasFormTarget: boolean
  declare readonly removeUrlValue: string

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  add(event: Event): void {
    event.preventDefault()

    if (!this.hasSelectTarget) return

    const studioId = this.selectTarget.value
    if (!studioId) return

    const url = this.formTarget.action

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ studio_id: studioId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to add to studio")
      })
      .then((data: { studio_id: number; studio_name: string; studio_path: string }) => {
        // Add studio to the list
        this.addStudioToList(data)
        // Remove option from select
        this.removeOptionFromSelect(String(data.studio_id))
      })
      .catch((error) => {
        console.error("Error adding to studio:", error)
        alert("Failed to add to studio")
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const studioId = button.dataset.studioId
    const studioName = button.dataset.studioName || "this studio"
    const url = this.removeUrlValue

    if (!studioId || !url) return

    if (!confirm(`Remove this subagent from ${studioName}?`)) return

    fetch(url, {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ studio_id: studioId }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Failed to remove from studio")
      })
      .then((data: { studio_id: number; studio_name: string }) => {
        // Remove studio from list
        this.removeStudioFromList(String(data.studio_id))
        // Add option back to select if it exists
        if (this.hasSelectTarget) {
          this.addOptionToSelect(String(data.studio_id), data.studio_name)
        }
      })
      .catch((error) => {
        console.error("Error removing from studio:", error)
        alert("Failed to remove from studio")
      })
  }

  private addStudioToList(data: { studio_id: number; studio_name: string; studio_path: string }): void {
    // Remove "None" message if present
    const noneMessage = this.studioListTarget.querySelector(".none-message")
    if (noneMessage) noneMessage.remove()

    // Create new studio item as <li>
    const item = document.createElement("li")
    item.className = "studio-item"
    item.dataset.studioId = String(data.studio_id)
    item.innerHTML = `<a href="${data.studio_path}">${data.studio_name}</a> <button type="button" class="button-small button-danger" data-action="subagent-studio-adder#remove" data-studio-id="${data.studio_id}" data-studio-name="${data.studio_name}">Remove from studio</button>`

    // Add to the list
    this.studioListTarget.appendChild(item)
  }

  private removeStudioFromList(studioId: string): void {
    const item = this.studioListTarget.querySelector(`.studio-item[data-studio-id="${studioId}"]`)
    if (item) {
      item.remove()
    }

    // Show "None" if no studios left
    const remainingItems = this.studioListTarget.querySelectorAll(".studio-item")
    if (remainingItems.length === 0) {
      const noneMessage = document.createElement("li")
      noneMessage.className = "none-message"
      noneMessage.innerHTML = "<em>Not a member of any studios</em>"
      this.studioListTarget.appendChild(noneMessage)
    }

    // Show the form if it was hidden
    if (this.hasFormTarget) {
      this.formTarget.style.display = ""
    }
  }

  private removeOptionFromSelect(studioId: string): void {
    if (!this.hasSelectTarget) return
    const option = this.selectTarget.querySelector(`option[value="${studioId}"]`)
    if (option) option.remove()
    this.selectTarget.value = ""

    // Hide the form if no more options
    if (this.selectTarget.options.length <= 1 && this.hasFormTarget) {
      this.formTarget.style.display = "none"
    }
  }

  private addOptionToSelect(studioId: string, studioName: string): void {
    if (!this.hasSelectTarget) return
    const option = document.createElement("option")
    option.value = studioId
    option.text = studioName
    this.selectTarget.appendChild(option)
  }
}
