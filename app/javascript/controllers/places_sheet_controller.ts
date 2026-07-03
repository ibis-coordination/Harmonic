import { Controller } from "@hotwired/stimulus"

/**
 * PlacesSheetController opens/closes the mobile place-switcher sheet and
 * lights the toggle's aggregate unread dot from the shared
 * "notifications:counts" broadcast (the badges inside the sheet are kept
 * fresh separately, by the sheet's own rail-badges controller).
 *
 * Registered on an ancestor of both the header toggle and the sheet
 * (the layout wraps them), since they live in different DOM subtrees.
 */
export default class PlacesSheetController extends Controller<HTMLElement> {
  static targets = ["panel", "backdrop", "toggle", "dot"]

  declare readonly panelTarget: HTMLElement
  declare readonly backdropTarget: HTMLElement
  declare readonly toggleTarget: HTMLElement
  declare readonly dotTarget: HTMLElement
  declare readonly hasPanelTarget: boolean
  declare readonly hasDotTarget: boolean

  connect(): void {
    document.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("notifications:counts", this.handleCounts)
  }

  disconnect(): void {
    document.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("notifications:counts", this.handleCounts)
  }

  toggle(): void {
    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  open(): void {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.add("open")
    this.panelTarget.setAttribute("aria-hidden", "false")
    this.backdropTarget.hidden = false
    this.toggleTarget.setAttribute("aria-expanded", "true")
  }

  close(): void {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.remove("open")
    this.panelTarget.setAttribute("aria-hidden", "true")
    this.backdropTarget.hidden = true
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }

  private isOpen(): boolean {
    return this.hasPanelTarget && this.panelTarget.classList.contains("open")
  }

  private handleKeydown = (event: KeyboardEvent): void => {
    if (event.key === "Escape" && this.isOpen()) {
      this.close()
    }
  }

  private handleCounts = (event: Event): void => {
    if (!this.hasDotTarget) return

    const detail = (event as CustomEvent).detail
    const byCollective: Record<string, number> = detail?.byCollective ?? {}
    const chat: number = detail?.chat ?? 0
    const anyUnread = chat > 0 || Object.values(byCollective).some((count) => count > 0)

    this.dotTarget.style.display = anyUnread ? "" : "none"
  }
}
