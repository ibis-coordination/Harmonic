import { Controller } from "@hotwired/stimulus"

/**
 * Handles AJAX-based action buttons in the Pulse feed.
 * Used for "Confirm read" (Notes) and "Join" (Commitments) actions.
 */
export default class PulseActionController extends Controller {
  static targets = ["button"]
  static values = {
    url: String,
    loadingText: String,
    confirmedText: String,
  }

  declare readonly buttonTarget: HTMLButtonElement
  declare readonly urlValue: string
  declare readonly loadingTextValue: string
  declare readonly confirmedTextValue: string

  private isLoading = false

  get csrfToken(): string {
    const meta = document.querySelector(
      "meta[name='csrf-token']"
    ) as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  async performAction(event: Event): Promise<void> {
    event.preventDefault()

    if (this.isLoading) return

    this.isLoading = true
    this.showLoadingState()

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": this.csrfToken,
        },
      })

      if (response.ok) {
        this.showConfirmedState()
      } else {
        // Revert to original state on error
        this.showErrorState()
      }
    } catch {
      this.showErrorState()
    }

    this.isLoading = false
  }

  private showLoadingState(): void {
    const button = this.buttonTarget
    const icon = button.querySelector(".octicon")

    // Store original content for error recovery
    button.dataset.originalHtml = button.innerHTML

    // Replace text with loading text, keep the icon
    if (icon) {
      button.innerHTML = ""
      button.appendChild(icon.cloneNode(true))
      button.appendChild(document.createTextNode(" " + this.loadingTextValue))
    } else {
      button.textContent = this.loadingTextValue
    }

    button.classList.add("pulse-feed-action-btn-loading")
    button.disabled = true
  }

  private showConfirmedState(): void {
    const button = this.buttonTarget
    const icon = button.querySelector(".octicon")

    // Replace text with confirmed text, keep the icon
    if (icon) {
      button.innerHTML = ""
      button.appendChild(icon.cloneNode(true))
      button.appendChild(document.createTextNode(" " + this.confirmedTextValue))
    } else {
      button.textContent = this.confirmedTextValue
    }

    button.classList.remove("pulse-feed-action-btn-loading")
    button.classList.add("pulse-feed-action-btn-disabled")
    button.disabled = true
  }

  private showErrorState(): void {
    const button = this.buttonTarget
    const originalHtml = button.dataset.originalHtml

    if (originalHtml) {
      button.innerHTML = originalHtml
    }

    button.classList.remove("pulse-feed-action-btn-loading")
    button.disabled = false
  }
}
