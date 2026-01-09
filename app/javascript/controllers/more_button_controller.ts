import { Controller } from "@hotwired/stimulus"

interface PinResponse {
  pinned: boolean
}

export default class MoreButtonController extends Controller {
  static targets = ["button", "menu", "plus", "plusMenu"]

  declare readonly buttonTarget: HTMLElement
  declare readonly menuTarget: HTMLElement
  declare readonly plusTarget: HTMLElement
  declare readonly plusMenuTarget: HTMLElement

  connect(): void {
    this.menuTarget.style.display = "none"
    document.addEventListener("click", (event: Event) => {
      const target = event.target as Node
      const isClickInside =
        this.menuTarget.contains(target) ||
        this.buttonTarget.contains(target) ||
        this.plusMenuTarget.contains(target) ||
        this.plusTarget.contains(target)
      const isClickOn =
        target === this.buttonTarget ||
        target === this.menuTarget ||
        target === this.plusTarget ||
        target === this.plusMenuTarget
      const isMenuVisible =
        this.menuTarget.style.display === "block" || this.plusMenuTarget.style.display === "block"
      if (!isClickInside && !isClickOn && isMenuVisible) {
        this.menuTarget.style.display = "none"
        this.plusMenuTarget.style.display = "none"
      }
    })
  }

  toggleMenu(): void {
    const rect = this.buttonTarget.getBoundingClientRect()
    const scrollTop = window.scrollY || document.documentElement.scrollTop
    this.menuTarget.style.position = "absolute"
    this.menuTarget.style.top = `${rect.bottom + scrollTop}px`
    this.menuTarget.style.right = `${window.innerWidth - rect.right}px`

    this.menuTarget.style.display = this.menuTarget.style.display === "none" ? "block" : "none"
    this.plusMenuTarget.style.display = "none"
  }

  togglePlusMenu(): void {
    const rect = this.plusTarget.getBoundingClientRect()
    const scrollTop = window.scrollY || document.documentElement.scrollTop
    this.plusMenuTarget.style.position = "absolute"
    this.plusMenuTarget.style.top = `${rect.bottom + scrollTop}px`
    this.plusMenuTarget.style.right = `${window.innerWidth - rect.right}px`

    this.plusMenuTarget.style.display = this.plusMenuTarget.style.display === "none" ? "block" : "none"
    this.menuTarget.style.display = "none"
  }

  get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  togglePin(event: Event): void {
    const target = event.target as HTMLElement
    const originalText = target.textContent?.trim() ?? ""
    const url = target.dataset.url
    if (!url) return

    const isPinned = originalText.split(" ")[0] === "Unpin"
    target.textContent = isPinned ? "Unpinning..." : "Pinning..."

    fetch(url, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({
        pinned: !isPinned,
      }),
    })
      .then((response) => {
        if (response.ok) return response.json()
        throw new Error("Network response was not ok.")
      })
      .then((responseBody: PinResponse) => {
        target.textContent = responseBody.pinned ? "Pinned!" : "Unpinned!"
        setTimeout(() => {
          target.textContent =
            (responseBody.pinned ? "Unpin from " : "Pin to ") +
            originalText.split(" ").slice(2).join(" ")
        }, 2000)
      })
  }

  pin(event: Event): void {
    this.togglePin(event)
  }
}
