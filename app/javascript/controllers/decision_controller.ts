import { Controller } from "@hotwired/stimulus"
import { getCsrfToken, fetchWithCsrf } from "../utils/csrf"

export default class DecisionController extends Controller {
  static targets = ["input", "list", "optionsSection"]

  declare readonly inputTarget: HTMLInputElement
  declare readonly listTarget: HTMLElement
  declare readonly optionsSectionTarget: HTMLElement

  private refreshing = false
  private updatingVotes = false
  private lastVoteUpdate = ""
  private previousOptionsListHtml = ""

  initialize(): void {
    document.addEventListener("poll", this.refreshOptions.bind(this))
  }

  add(event: Event): void {
    event.preventDefault()
    const input = this.inputTarget.value.trim()
    if (input.length > 0) {
      this.createOption(input)
        .then((response) => response.text())
        .then((html) => {
          this.listTarget.innerHTML = html
          this.inputTarget.value = ""
        })
        .catch((error) => {
          console.error("Error creating option:", error)
        })
    }
  }

  get decisionIsClosed(): boolean {
    if (!this.optionsSectionTarget.dataset.deadline) return false
    try {
      const deadlineDate = new Date(this.optionsSectionTarget.dataset.deadline)
      const now = new Date()
      return now > deadlineDate
    } catch (error) {
      console.error("Error determining if decision is closed:", error)
      return false
    }
  }

  async createOption(title: string): Promise<Response> {
    const url = this.optionsSectionTarget.dataset.url
    if (!url) {
      throw new Error("No URL specified for creating option")
    }

    const response = await fetchWithCsrf(url, {
      method: "POST",
      body: JSON.stringify({ title }),
    })

    if (!response.ok) {
      throw new Error(`API request failed with status ${response.status}`)
    }
    const ddu = new Event("decisionDataUpdated")
    document.dispatchEvent(ddu)
    return response
  }

  nextVoteState(accepted: boolean, preferred: boolean): [boolean, boolean] {
    if (preferred) {
      return [false, false]
    } else if (accepted) {
      return [true, true]
    } else {
      return [true, false]
    }
  }

  async toggleVoteValues(event: Event): Promise<void> {
    const studioHandle = window.location.pathname.startsWith("/studios/")
      ? window.location.pathname.split("/")[2]
      : null
    const urlPrefix = studioHandle ? `/studios/${studioHandle}` : ""
    const decisionId = this.inputTarget.dataset.decisionId

    const target = event.target as HTMLElement
    const optionItem = target.closest(".pulse-option-item") as HTMLElement | null
    if (!optionItem) return

    const checkbox = optionItem.querySelector("input.pulse-acceptance-checkbox") as HTMLInputElement | null
    const starButton = optionItem.querySelector("input.pulse-star-checkbox") as HTMLInputElement | null
    if (!checkbox || !starButton) return

    const isToggleClick = target === checkbox || target === starButton

    const optionId = optionItem.dataset.optionId
    let accepted = checkbox.checked
    let preferred = starButton.checked

    if (!isToggleClick) {
      ;[accepted, preferred] = this.nextVoteState(accepted, preferred)
      checkbox.checked = accepted
      starButton.checked = preferred
    }

    this.updatingVotes = true
    await fetchWithCsrf(`${urlPrefix}/api/v1/decisions/${decisionId}/options/${optionId}/votes`, {
      method: "POST",
      body: JSON.stringify({ accepted, preferred }),
    })
    this.updatingVotes = false
    this.lastVoteUpdate = new Date().toString()
    const ddu = new Event("decisionDataUpdated")
    document.dispatchEvent(ddu)
  }

  async cycleVoteState(event: Event): Promise<void> {
    const target = event.target as HTMLElement
    if (target.tagName === "A") return
    event.preventDefault()
    return this.toggleVoteValues(event)
  }

  async refreshOptions(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing || this.updatingVotes) return
    this.refreshing = true

    const url = this.optionsSectionTarget.dataset.url
    if (!url) {
      this.refreshing = false
      return
    }

    const lastVoteUpdateBeforeRefresh = this.lastVoteUpdate

    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
        },
      })

      const refreshIsStale =
        this.updatingVotes || this.lastVoteUpdate !== lastVoteUpdateBeforeRefresh

      if (refreshIsStale) {
        // Skip this stale refresh
      } else if (response.ok) {
        const html = await response.text()
        if (html !== this.previousOptionsListHtml) {
          this.listTarget.innerHTML = html
          this.previousOptionsListHtml = html
        } else if (this.decisionIsClosed) {
          this.hideOptions()
        }
      } else {
        console.error("Error refreshing options:", response)
      }
    } finally {
      this.refreshing = false
    }
  }

  hideOptions(): void {
    this.optionsSectionTarget.style.display = "none"
  }
}
