import { Controller } from "@hotwired/stimulus"

export default class TopRightMenuController extends Controller {
  static targets = ["button", "menu", "quickAppendInput"]

  declare readonly buttonTarget: HTMLElement
  declare readonly menuTarget: HTMLElement
  declare readonly quickAppendInputTarget: HTMLInputElement
  declare readonly hasQuickAppendInputTarget: boolean

  connect(): void {
    this.menuTarget.style.display = "none"
    document.addEventListener("click", (event: Event) => {
      const target = event.target as Node
      const isClickInside = this.menuTarget.contains(target) || this.buttonTarget.contains(target)
      const isClickOn = target === this.buttonTarget || target === this.menuTarget
      const isMenuVisible = this.menuTarget.style.display === "block"
      if (!isClickInside && !isClickOn && isMenuVisible) {
        this.menuTarget.style.display = "none"
        if (this.hasQuickAppendInputTarget) {
          this.quickAppendInputTarget.value = ""
        }
      }
    })
  }

  toggleMenu(): void {
    const rect = this.buttonTarget.getBoundingClientRect()
    this.menuTarget.style.top = `${rect.bottom}px`
    this.menuTarget.style.right = `${window.innerWidth - rect.right}px`
    this.menuTarget.style.display = this.menuTarget.style.display === "none" ? "block" : "none"
  }
}
