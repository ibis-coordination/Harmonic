import { Controller } from "@hotwired/stimulus"

interface PinResponse {
  pinned: boolean
  click_title: string
}

export default class PinController extends Controller {
  static targets = ["pinButton", "label", "iconPin", "iconUnpin"]

  declare readonly pinButtonTarget: HTMLElement
  declare readonly hasLabelTarget: boolean
  declare readonly labelTarget: HTMLElement
  declare readonly hasIconPinTarget: boolean
  declare readonly iconPinTarget: HTMLElement
  declare readonly hasIconUnpinTarget: boolean
  declare readonly iconUnpinTarget: HTMLElement
  private isPinned = false

  connect(): void {
    this.pinButtonTarget.addEventListener("click", this.togglePin.bind(this))
    this.isPinned = this.pinButtonTarget.dataset.isPinned === "true"
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  togglePin(): void {
    const url = this.pinButtonTarget.dataset.pinUrl
    if (!url) return

    // Show loading state with opacity
    this.pinButtonTarget.style.opacity = "0.5"

    fetch(url, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({
        pinned: !this.isPinned,
      }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Network response was not ok.")
      })
      .then((responseBody: PinResponse) => {
        this.isPinned = responseBody.pinned
        this.pinButtonTarget.title = responseBody.click_title
        this.pinButtonTarget.style.opacity = "1"
        // Check if this is a Pulse-styled button (has label target) or legacy button
        if (this.hasLabelTarget) {
          // Pulse-styled button: update label text and icons
          this.labelTarget.textContent = this.isPinned ? "Unpin" : "Pin"
          if (this.hasIconPinTarget && this.hasIconUnpinTarget) {
            this.iconPinTarget.style.display = this.isPinned ? "none" : ""
            this.iconUnpinTarget.style.display = this.isPinned ? "" : "none"
          }
        } else {
          // Legacy button: update opacity based on pinned state
          this.pinButtonTarget.style.opacity = this.isPinned ? "1" : "0.2"
        }
      })
      .catch(() => {
        // Restore opacity on error
        this.pinButtonTarget.style.opacity = "1"
      })
  }
}
