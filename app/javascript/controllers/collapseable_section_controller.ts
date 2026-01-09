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

  connect(): void {
    this.hidden = this.bodyTarget.style.display === "none"
    this.headerTarget.addEventListener("click", this.toggle.bind(this))
    this.headerTarget.style.cursor = "pointer"
    this.lazyLoadCompleted = !this.lazyLoadTarget.dataset.url
    if (!this.hidden) {
      this.show()
    }
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  toggle(): void {
    if (this.hidden) {
      this.show()
    } else {
      this.hide()
    }
  }

  hide(): void {
    this.bodyTarget.style.display = "none"
    this.triangleRightTarget.style.display = "inline"
    this.triangleDownTarget.style.display = "none"
    this.hidden = true
  }

  show(): void {
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
          })
      }
    }
    this.bodyTarget.style.display = "block"
    this.triangleRightTarget.style.display = "none"
    this.triangleDownTarget.style.display = "inline"
    this.hidden = false
  }

  showLoading(): void {
    this.lazyLoadTarget.innerHTML = "<ul><li>...</li></ul>"
  }
}
