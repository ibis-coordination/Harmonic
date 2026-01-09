import { Controller } from "@hotwired/stimulus"

export default class DecisionVotersController extends Controller {
  static targets: string[] = []
  static values = { url: String }

  declare urlValue: string

  private refreshing = false
  private previousHtml = ""

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  initialize(): void {
    document.addEventListener("decisionDataUpdated", this.refreshVoters.bind(this))
  }

  async refreshVoters(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    this.refreshing = true

    try {
      const response = await fetch(this.urlValue, {
        method: "GET",
        headers: {
          "X-CSRF-Token": this.csrfToken,
        },
      })

      if (response.ok) {
        const html = await response.text()
        if (html !== this.previousHtml) {
          this.element.innerHTML = html
          this.previousHtml = html
        }
      } else {
        console.error("Error refreshing results:", response)
      }
    } finally {
      this.refreshing = false
    }
  }
}
