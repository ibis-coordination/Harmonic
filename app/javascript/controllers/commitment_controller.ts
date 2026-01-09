import { Controller } from "@hotwired/stimulus"

export default class CommitmentController extends Controller {
  static targets = ["joinButton", "joinButtonMessage", "joinSection", "statusSection", "participantsList"]

  declare readonly joinButtonTarget: HTMLElement
  declare readonly joinButtonMessageTarget: HTMLElement
  declare readonly joinSectionTarget: HTMLElement
  declare readonly statusSectionTarget: HTMLElement
  declare readonly participantsListTarget: HTMLElement

  private editingName = false
  private refreshing = false
  private currentParticipantsListLimit = 0

  initialize(): void {
    // document.addEventListener('poll', this.refreshDisplay.bind(this))
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  async join(event: Event): Promise<void> {
    event.preventDefault()
    if (this.editingName) return

    this.joinButtonTarget.innerHTML = "Joining..."
    const url = this.joinButtonTarget.dataset.url
    if (!url) return

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({
          committed: true,
        }),
      })
      const html = await response.text()
      this.joinButtonTarget.remove()
      this.joinSectionTarget.innerHTML = html
      this.refreshStatusSection(event)
      this.refreshParticipantsList(event)
      const mc = new Event("metricChange")
      document.dispatchEvent(mc)
    } catch (error) {
      console.error("Error joining commitment:", error)
      this.joinSectionTarget.innerHTML = "Something went wrong. Please refresh the page and try again."
    }
  }

  joinButtonMouseEnter(_event: Event): void {
    this.joinButtonMessageTarget.style.textDecoration = "underline"
  }

  joinButtonMouseLeave(_event: Event): void {
    this.joinButtonMessageTarget.style.textDecoration = ""
  }

  async refreshStatusSection(event: Event): Promise<void> {
    event.preventDefault()
    const url = this.statusSectionTarget.dataset.url
    if (!url) return

    try {
      const response = await fetch(url)
      const html = await response.text()
      this.statusSectionTarget.innerHTML = html
    } catch (error) {
      console.error("Error refreshing status:", error)
    }
  }

  async refreshParticipantsList(event: Event): Promise<void> {
    event.preventDefault()
    if (!this.currentParticipantsListLimit) {
      this.currentParticipantsListLimit = +(this.participantsListTarget.dataset.limit ?? 0)
    }
    const limit = this.currentParticipantsListLimit
    const baseUrl = this.participantsListTarget.dataset.url
    if (!baseUrl) return

    const url = `${baseUrl}?limit=${limit}`
    try {
      const response = await fetch(url)
      const html = await response.text()
      this.participantsListTarget.innerHTML = html
    } catch (error) {
      console.error("Error showing more participants:", error)
    }
  }

  async showMoreParticipants(event: Event): Promise<void> {
    if (!this.currentParticipantsListLimit) {
      this.currentParticipantsListLimit = +(this.participantsListTarget.dataset.limit ?? 0)
    }
    this.currentParticipantsListLimit += 10
    return this.refreshParticipantsList(event)
  }

  async refreshDisplay(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    this.refreshing = true
    this.refreshing = false
  }
}
