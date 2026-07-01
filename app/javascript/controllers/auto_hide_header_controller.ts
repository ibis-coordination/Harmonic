import { Controller } from "@hotwired/stimulus"

// Auto-hiding top header.
//
// Hides the app header (translated off-screen via a CSS class) when the user
// scrolls down, and reveals it again when they scroll up or return to the top
// of the page. Attaches to <header class="pulse-top-header"> in the layout.
//
//   <header class="pulse-top-header"
//           data-controller="auto-hide-header"
//           data-auto-hide-header-hidden-class="pulse-top-header--hidden">
//
// The reveal-on-scroll-up behaviour keeps the header one flick away without it
// eating vertical space while reading, which matters most on small screens.
export default class AutoHideHeaderController extends Controller<HTMLElement> {
  static classes = ["hidden"]
  static values = {
    // Minimum scroll distance (px) before we react, to avoid jitter.
    threshold: { type: Number, default: 8 },
  }

  declare readonly hiddenClass: string
  declare readonly hasHiddenClass: boolean
  declare readonly thresholdValue: number

  private lastScrollY = 0
  private ticking = false
  private readonly onScroll = (): void => this.requestUpdate()
  private readonly onFocusIn = (): void => this.reveal()

  connect(): void {
    this.lastScrollY = this.currentScrollY()
    // A restored Turbo snapshot may bring back a stale hidden class; always
    // start visible so navigation never lands on an invisible header.
    this.reveal()
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.element.addEventListener("focusin", this.onFocusIn)
  }

  disconnect(): void {
    window.removeEventListener("scroll", this.onScroll)
    this.element.removeEventListener("focusin", this.onFocusIn)
  }

  private requestUpdate(): void {
    if (this.ticking) return
    this.ticking = true
    window.requestAnimationFrame(() => {
      this.update()
      this.ticking = false
    })
  }

  update(): void {
    const current = this.currentScrollY()
    const delta = current - this.lastScrollY
    const headerHeight = this.element.offsetHeight

    if (current <= headerHeight) {
      // Near the top of the page: keep the header pinned.
      this.reveal()
    } else if (delta > this.thresholdValue) {
      this.hide()
    } else if (delta < -this.thresholdValue) {
      this.reveal()
    }

    this.lastScrollY = current
  }

  private hide(): void {
    this.element.classList.add(this.hiddenClassName)
  }

  private reveal(): void {
    this.element.classList.remove(this.hiddenClassName)
  }

  private get hiddenClassName(): string {
    return this.hasHiddenClass ? this.hiddenClass : "pulse-top-header--hidden"
  }

  private currentScrollY(): number {
    // Clamp negative offsets from iOS rubber-band overscroll.
    return Math.max(0, window.scrollY)
  }
}
