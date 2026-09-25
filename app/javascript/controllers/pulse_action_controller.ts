import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * Handles AJAX-based action buttons in the Pulse feed.
 * Used for "Confirm read" (Notes) and "Join" (Commitments) actions.
 *
 * For "Confirm read", the JSON response includes the updated `confirmed_reads`
 * count. When a count block is present we update the "N confirmed" figure live
 * (revealing it, and the viewer's avatar, on the first confirmation) so it
 * stays in sync without a page reload. Actions without a count target — e.g.
 * the Commitment "Join" button — just flip the button as before.
 */
export default class PulseActionController extends Controller {
  static targets = ["button", "count", "readCount", "selfAvatar"]
  static values = {
    url: String,
    loadingText: String,
    confirmedText: String,
  }

  declare readonly buttonTarget: HTMLButtonElement
  declare readonly countTarget: HTMLElement
  declare readonly hasCountTarget: boolean
  declare readonly readCountTarget: HTMLElement
  declare readonly hasReadCountTarget: boolean
  declare readonly selfAvatarTarget: HTMLElement
  declare readonly hasSelfAvatarTarget: boolean
  declare readonly urlValue: string
  declare readonly loadingTextValue: string
  declare readonly confirmedTextValue: string

  private isLoading = false

  async performAction(event: Event): Promise<void> {
    event.preventDefault()

    if (this.isLoading) return

    this.isLoading = true
    this.showLoadingState()

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
          Accept: "application/json",
        },
      })

      if (response.ok) {
        this.showConfirmedState()
        await this.updateReadCount(response)
      } else {
        // Revert to original state on error
        this.showErrorState()
      }
    } catch {
      this.showErrorState()
    }

    this.isLoading = false
  }

  // Sync the "N confirmed" figure from the JSON body. No-op for actions that
  // don't render a count (e.g. Commitment "Join") or when the body isn't the
  // expected JSON, so those paths keep their prior behavior.
  private async updateReadCount(response: Response): Promise<void> {
    if (!this.hasCountTarget) return

    let confirmedReads: unknown
    try {
      const data = await response.json()
      confirmedReads = data?.confirmed_reads
    } catch {
      return
    }
    if (typeof confirmedReads !== "number") return

    this.countTarget.textContent = `${confirmedReads} confirmed`

    // First confirmation: the count block (and the viewer's avatar) start
    // hidden because the server rendered zero reads. Reveal them now.
    if (this.hasReadCountTarget) {
      this.readCountTarget.hidden = false
    }
    if (this.hasSelfAvatarTarget) {
      this.selfAvatarTarget.hidden = false
    }
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
