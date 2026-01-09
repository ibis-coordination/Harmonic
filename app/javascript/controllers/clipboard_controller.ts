import { Controller } from "@hotwired/stimulus"

export default class ClipboardController extends Controller {
  static targets = ["button", "source", "successMessage"]

  declare readonly buttonTarget: HTMLElement
  declare readonly sourceTarget: HTMLInputElement
  declare readonly successMessageTarget: HTMLElement

  private timeout: ReturnType<typeof setTimeout> | null = null

  copy(event: Event): void {
    event.preventDefault()

    const text = this.sourceTarget.value

    navigator.clipboard.writeText(text).then(() => this.copied())
  }

  copied(): void {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    this.buttonTarget.style.display = "none"
    this.successMessageTarget.style.display = "inline"

    this.timeout = setTimeout(() => {
      this.buttonTarget.style.display = "inline"
      this.successMessageTarget.style.display = "none"
    }, 2000)
  }
}
