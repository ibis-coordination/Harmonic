import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

export default class DecisionResultsController extends Controller {
  static targets = ["header", "content"]
  static values = { url: String }

  declare readonly headerTarget: HTMLElement
  declare readonly contentTarget: HTMLElement
  declare urlValue: string

  private refreshing = false
  private previousHtml = ""

  initialize(): void {
    document.addEventListener("decisionDataUpdated", this.refreshResults.bind(this))
    document.addEventListener("poll", this.refreshResults.bind(this))
  }

  async refreshResults(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    this.refreshing = true

    try {
      const response = await fetch(this.urlValue, {
        method: "GET",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
        },
      })

      if (response.ok) {
        const html = await response.text()
        if (html !== this.previousHtml) {
          this.contentTarget.innerHTML = html
          this.previousHtml = html
          const firstChild = this.contentTarget.children[0] as HTMLElement | undefined
          const newHeaderText = firstChild?.dataset.header
          if (newHeaderText) {
            this.headerTarget.textContent = newHeaderText
          }
        }
      } else {
        console.error("Error refreshing results:", response)
      }
    } finally {
      this.refreshing = false
    }
  }
}
