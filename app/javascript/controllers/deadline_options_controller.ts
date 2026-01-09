import { Controller } from "@hotwired/stimulus"

export default class DeadlineOptionsController extends Controller {
  static targets: string[] = []

  connect(): void {
    this.element.addEventListener("click", this.selectOption.bind(this))
  }

  selectOption(event: Event): void {
    const target = event.target as HTMLElement
    let optionContainer = target.parentElement
    if (!optionContainer?.classList.contains("deadline-option")) {
      optionContainer = optionContainer?.parentElement ?? null
    }
    if (optionContainer) {
      const radio = optionContainer.children[0] as HTMLInputElement
      radio.checked = true
    }
  }
}
