import { Controller } from "@hotwired/stimulus"

export default class TopRightMenuController extends Controller {
  static targets = ["button", "menu", "quickAppendInput"]
  // openUp: the menu opens above the button instead of below — for
  // instances anchored to the bottom tab bar. Positioning is pure CSS
  // (bottom: 100% inside the positioned wrapper); measuring here would
  // read offsetParent while the menu is display:none, which resolves to
  // <body> and mispositions on scrolled pages.
  static values = { openUp: { type: Boolean, default: false } }

  declare readonly buttonTarget: HTMLElement
  declare readonly menuTarget: HTMLElement
  declare readonly quickAppendInputTarget: HTMLInputElement
  declare readonly hasQuickAppendInputTarget: boolean
  declare openUpValue: boolean

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
    if (!this.openUpValue) {
      const rect = this.buttonTarget.getBoundingClientRect()
      const offsetParent = (this.menuTarget.offsetParent || document.body) as HTMLElement
      const parentRect = offsetParent.getBoundingClientRect()
      this.menuTarget.style.top = `${rect.bottom - parentRect.top}px`
      this.menuTarget.style.right = `${parentRect.right - rect.right}px`
    }
    this.menuTarget.style.display = this.menuTarget.style.display === "none" ? "block" : "none"
  }
}
