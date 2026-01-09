import { Controller } from "@hotwired/stimulus"

export default class TooltipController extends Controller {
  static targets = ["info", "x"]

  declare readonly infoTarget: HTMLElement
  declare readonly xTarget: HTMLElement

  private showing = false
  private canHide = true
  private hideTimeout: ReturnType<typeof setTimeout> | null = null

  connect(): void {
    this.element.addEventListener("mouseenter", this.show.bind(this))
    this.element.addEventListener("mouseleave", this.hideWithDelay.bind(this))
    this.infoTarget.addEventListener("mouseenter", this.preventHide.bind(this))
    this.infoTarget.addEventListener("mouseleave", this.enableHide.bind(this))

    // if mobile
    if (window.innerWidth < 768) {
      this.connectMobile()
    }
  }

  connectMobile(): void {
    this.element.addEventListener("click", this.toggle.bind(this))
    this.xTarget.style.display = "inline-block"

    this.infoTarget.addEventListener("click", (event: Event) => {
      event.stopPropagation()
    })

    document.addEventListener("click", (event: Event) => {
      const target = event.target as Node
      if (this.showing && !this.element.contains(target)) {
        this.hideImmediately()
      }
    })

    this.xTarget.addEventListener("click", () => {
      this.hideImmediately()
    })
  }

  show(): void {
    this.infoTarget.style.display = "block"
    const rect = this.element.getBoundingClientRect()
    const infoRect = this.infoTarget.getBoundingClientRect()
    const top = Math.max(15, rect.top - infoRect.height + window.scrollY)
    const left = Math.max(15, rect.left + rect.width / 2 - infoRect.width / 2)
    this.infoTarget.style.top = `${top}px`
    this.infoTarget.style.left = `${left}px`
    this.showing = true
  }

  hideWithDelay(): void {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
    }
    this.hideTimeout = setTimeout(() => {
      if (this.canHide) {
        this.infoTarget.style.display = "none"
        this.showing = false
      }
    }, 300)
  }

  hideImmediately(): void {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
    }
    this.infoTarget.style.display = "none"
    this.showing = false
  }

  preventHide(): void {
    this.canHide = false
  }

  enableHide(): void {
    this.canHide = true
  }

  toggle(): void {
    if (this.showing) {
      this.hideImmediately()
    } else {
      this.show()
    }
  }
}
