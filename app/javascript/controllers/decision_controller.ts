import { Controller } from "@hotwired/stimulus"
import { getCsrfToken, fetchWithCsrf } from "../utils/csrf"

export default class DecisionController extends Controller {
  static targets = ["input", "list", "optionsSection", "voteForm", "submitButton", "addOptionForm", "voteNotice", "submitRow", "votingHint"]

  declare readonly inputTarget: HTMLInputElement
  declare readonly listTarget: HTMLElement
  declare readonly hasListTarget: boolean
  declare readonly optionsSectionTarget: HTMLElement
  declare readonly hasOptionsSectionTarget: boolean
  declare readonly hasVoteFormTarget: boolean
  declare readonly voteFormTarget: HTMLFormElement
  declare readonly hasSubmitButtonTarget: boolean
  declare readonly submitButtonTarget: HTMLButtonElement
  declare readonly hasVoteNoticeTarget: boolean
  declare readonly voteNoticeTarget: HTMLElement
  declare readonly hasSubmitRowTarget: boolean
  declare readonly submitRowTarget: HTMLElement
  declare readonly hasVotingHintTarget: boolean
  declare readonly votingHintTarget: HTMLElement

  private refreshing = false
  private previousOptionsListHtml = ""
  private initialVoteState: string = ""

  initialize(): void {
    document.addEventListener("poll", this.refreshOptions.bind(this))
  }

  connect(): void {
    if (!this.hasListTarget) return
    this.captureInitialState()
    this.updateSubmitButton()
    this.listenForChanges()
  }

  add(event: Event): void {
    event.preventDefault()
    const input = this.inputTarget.value.trim()
    if (input.length > 0) {
      this.createOption(input)
        .then((response) => response.text())
        .then((html) => {
          // Parse the response and append only the new option,
          // preserving local checkbox state for existing options.
          const template = document.createElement("template")
          template.innerHTML = html
          const existingIds = new Set(
            Array.from(this.listTarget.querySelectorAll("li[data-option-id]")).map(
              (el) => (el as HTMLElement).dataset.optionId
            )
          )
          const newItems = template.content.querySelectorAll("li[data-option-id]")
          newItems.forEach((item) => {
            const optionId = (item as HTMLElement).dataset.optionId
            if (optionId && !existingIds.has(optionId)) {
              this.listTarget.appendChild(item.cloneNode(true))
            }
          })
          this.inputTarget.value = ""
          // Extend the initial state to include the new unchecked option
          this.initialVoteState = this.initialVoteState +
            (this.initialVoteState ? "," : "") + "0,0"
          this.updateSubmitButton()
          this.listenForChanges()
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

  private captureInitialState(): void {
    this.initialVoteState = this.currentVoteState()
  }

  private currentVoteState(): string {
    const checkboxes = this.listTarget.querySelectorAll(
      "input.pulse-acceptance-checkbox, input.pulse-star-checkbox"
    )
    return Array.from(checkboxes)
      .map((cb) => (cb as HTMLInputElement).checked ? "1" : "0")
      .join(",")
  }

  private hasVoteChanged(): boolean {
    return this.currentVoteState() !== this.initialVoteState
  }

  private updateSubmitButton(): void {
    if (!this.hasSubmitButtonTarget) return
    const hasOptions = this.listTarget.querySelectorAll("li[data-option-id]").length > 0
    if (this.hasSubmitRowTarget) {
      this.submitRowTarget.style.display = hasOptions ? "" : "none"
    }
    if (this.hasVotingHintTarget) {
      this.votingHintTarget.style.display = hasOptions ? "" : "none"
    }
    const changed = this.hasVoteChanged()
    this.submitButtonTarget.disabled = !changed
    if (this.hasVoteNoticeTarget) {
      this.voteNoticeTarget.style.display = changed ? "" : "none"
    }
  }

  private listenForChanges(): void {
    const checkboxes = this.listTarget.querySelectorAll(
      "input.pulse-acceptance-checkbox, input.pulse-star-checkbox"
    )
    checkboxes.forEach((cb) => {
      cb.addEventListener("change", () => this.updateSubmitButton())
    })
  }

  async refreshOptions(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    if (!this.hasOptionsSectionTarget || !this.hasListTarget) return
    this.refreshing = true

    const url = this.optionsSectionTarget.dataset.url
    if (!url) {
      this.refreshing = false
      return
    }

    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
        },
      })

      if (response.ok) {
        const html = await response.text()
        if (html !== this.previousOptionsListHtml) {
          this.previousOptionsListHtml = html
          // Parse the new HTML and add only options that don't already exist,
          // preserving the user's local checkbox state for existing options.
          const template = document.createElement("template")
          template.innerHTML = html
          const newItems = template.content.querySelectorAll("li[data-option-id]")
          const existingIds = new Set(
            Array.from(this.listTarget.querySelectorAll("li[data-option-id]")).map(
              (el) => (el as HTMLElement).dataset.optionId
            )
          )
          newItems.forEach((item) => {
            const optionId = (item as HTMLElement).dataset.optionId
            if (optionId && !existingIds.has(optionId)) {
              this.listTarget.appendChild(item.cloneNode(true))
              this.captureInitialState()
              this.updateSubmitButton()
              this.listenForChanges()
            }
          })
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
