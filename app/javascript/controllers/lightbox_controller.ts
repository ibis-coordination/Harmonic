import { Controller } from "@hotwired/stimulus"

// Click any element marked with [data-lightbox-target="trigger"] to open
// a fullscreen overlay showing the full-resolution image. Esc or
// click-outside closes. Triggers carry their image URL + alt + caption
// via params, so the controller stays stateless about which images exist.
export default class LightboxController extends Controller<HTMLElement> {
  static targets = ["trigger"]

  declare readonly triggerTargets: HTMLButtonElement[]

  private backdrop: HTMLDivElement | null = null
  private boundKeydown = (event: KeyboardEvent) => this.handleKeydown(event)

  disconnect() {
    this.close()
  }

  open(event: Event) {
    event.preventDefault()
    const target = event.currentTarget as HTMLElement
    const url = target.dataset.lightboxLargeUrlParam || ""
    const alt = target.dataset.lightboxAltParam || ""
    const caption = target.dataset.lightboxCaptionParam || ""

    if (!url) return

    this.render(url, alt, caption)
  }

  close() {
    if (this.backdrop) {
      this.backdrop.remove()
      this.backdrop = null
      document.removeEventListener("keydown", this.boundKeydown)
      document.body.style.overflow = ""
    }
  }

  private render(url: string, alt: string, caption: string) {
    this.close()

    const backdrop = document.createElement("div")
    backdrop.className = "lightbox-backdrop"
    backdrop.setAttribute("role", "dialog")
    backdrop.setAttribute("aria-modal", "true")
    backdrop.addEventListener("click", (event) => {
      if (event.target === backdrop) this.close()
    })

    const img = document.createElement("img")
    img.src = url
    img.alt = alt
    img.className = "lightbox-img"
    backdrop.appendChild(img)

    if (caption.trim().length > 0) {
      const cap = document.createElement("div")
      cap.className = "lightbox-caption"
      cap.textContent = caption
      backdrop.appendChild(cap)
    }

    const closeBtn = document.createElement("button")
    closeBtn.type = "button"
    closeBtn.className = "lightbox-close"
    closeBtn.setAttribute("aria-label", "Close image viewer")
    closeBtn.textContent = "×"
    closeBtn.addEventListener("click", () => this.close())
    backdrop.appendChild(closeBtn)

    document.body.appendChild(backdrop)
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", this.boundKeydown)
    closeBtn.focus()
    this.backdrop = backdrop
  }

  private handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }
}
