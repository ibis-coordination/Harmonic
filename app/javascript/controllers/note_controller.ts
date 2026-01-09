import { Controller } from "@hotwired/stimulus"

export default class NoteController extends Controller {
  static targets = ["confirmButton", "confirmButtonMessage", "confirmSection", "historyLog"]

  declare readonly confirmButtonTarget: HTMLElement
  declare readonly confirmButtonMessageTarget: HTMLElement
  declare readonly confirmSectionTarget: HTMLElement
  declare readonly historyLogTarget: HTMLElement

  private editingName = false
  private refreshing = false

  connect(): void {
    // connected
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  async confirm(event: Event): Promise<void> {
    event.preventDefault()
    if (this.editingName) return

    this.confirmButtonTarget.innerHTML = "Confirming..."
    const url = this.confirmButtonTarget.dataset.url
    if (!url) return

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({
          confirmed: true,
        }),
      })
      const html = await response.text()
      this.confirmButtonTarget.remove()
      this.confirmSectionTarget.innerHTML = html
      const mc = new Event("metricChange")
      document.dispatchEvent(mc)
    } catch (error) {
      console.error("Error confirming read:", error)
      this.confirmSectionTarget.innerHTML = "Something went wrong. Please refresh the page and try again."
    }
  }

  confirmButtonMouseEnter(_event: Event): void {
    if (this.editingName) return
    this.confirmButtonMessageTarget.style.textDecoration = "underline"
  }

  confirmButtonMouseLeave(_event: Event): void {
    this.confirmButtonMessageTarget.style.textDecoration = ""
  }

  async refreshDisplay(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    this.refreshing = true
    this.refreshing = false
  }
}
