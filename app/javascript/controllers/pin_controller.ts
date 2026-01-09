import { Controller } from "@hotwired/stimulus"

interface PinResponse {
  pinned: boolean
  click_title: string
}

export default class PinController extends Controller {
  static targets = ["pinButton"]

  declare readonly pinButtonTarget: HTMLElement
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
        this.pinButtonTarget.style.opacity = this.isPinned ? "1" : "0.2"
        this.pinButtonTarget.title = responseBody.click_title
      })
  }
}
