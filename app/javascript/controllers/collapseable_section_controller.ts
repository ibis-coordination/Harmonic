import { Controller } from "@hotwired/stimulus"

export default class CollapsableSectionController extends Controller {
  static targets = ["header", "body", "triangleRight", "triangleDown", "lazyLoad"]

  declare readonly headerTarget: HTMLElement
  declare readonly bodyTarget: HTMLElement
  declare readonly triangleRightTarget: HTMLElement
  declare readonly triangleDownTarget: HTMLElement
  declare readonly lazyLoadTarget: HTMLElement

  private hidden = false
  private lazyLoadCompleted = false
  private animating = false

  connect(): void {
    this.hidden = this.bodyTarget.style.display === "none"
    this.headerTarget.addEventListener("click", this.toggle.bind(this))
    this.headerTarget.style.cursor = "pointer"
    this.lazyLoadCompleted = !this.lazyLoadTarget.dataset.url

    // Set up for animation
    this.bodyTarget.style.overflow = "hidden"
    this.bodyTarget.style.transition = "max-height 0.25s ease-in-out"

    if (this.hidden) {
      this.bodyTarget.style.maxHeight = "0"
      this.bodyTarget.style.display = "block"
    } else {
      // Let it render first, then set max-height
      requestAnimationFrame(() => {
        this.bodyTarget.style.maxHeight = this.bodyTarget.scrollHeight + "px"
      })
    }
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  toggle(): void {
    if (this.animating) return

    if (this.hidden) {
      this.show()
    } else {
      this.hide()
    }
  }

  hide(): void {
    this.animating = true

    // First, set max-height to current height (so we can animate from it)
    this.bodyTarget.style.maxHeight = this.bodyTarget.scrollHeight + "px"

    // Force reflow
    this.bodyTarget.offsetHeight

    // Then animate to 0
    this.bodyTarget.style.maxHeight = "0"

    this.triangleRightTarget.style.display = "inline"
    this.triangleDownTarget.style.display = "none"
    this.hidden = true

    setTimeout(() => {
      this.animating = false
    }, 250)
  }

  show(): void {
    this.animating = true

    if (this.lazyLoadCompleted !== true) {
      this.showLoading()
      const url = this.lazyLoadTarget.dataset.url
      if (url) {
        fetch(url, {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": this.csrfToken,
          },
        })
          .then((response) => response.text())
          .then((html) => {
            this.bodyTarget.innerHTML = html
            this.lazyLoadCompleted = true
            // Update max-height after content loads
            this.bodyTarget.style.maxHeight = this.bodyTarget.scrollHeight + "px"
          })
      }
    }

    // Animate to full height
    this.bodyTarget.style.maxHeight = this.bodyTarget.scrollHeight + "px"

    this.triangleRightTarget.style.display = "none"
    this.triangleDownTarget.style.display = "inline"
    this.hidden = false

    setTimeout(() => {
      this.animating = false
      // After animation, allow content to grow naturally
      this.bodyTarget.style.maxHeight = "none"
    }, 250)
  }

  showLoading(): void {
    this.lazyLoadTarget.innerHTML = "<ul><li>...</li></ul>"
  }
}
