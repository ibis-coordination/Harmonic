import { Controller } from "@hotwired/stimulus"

// Pull-to-refresh for the installed PWA (#401, pairs with the mobile back
// button #322).
//
// A browser gives you pull-to-refresh for free, but a PWA in standalone /
// fullscreen display has no browser chrome and no native overscroll refresh —
// so the same gesture that reloads any web page does nothing once Harmonic is
// installed to the home screen. This wires it up ourselves, but ONLY in that
// standalone case: in a normal mobile browser the platform still owns the
// gesture and we must not double up on it.
//
// Wired on <body> (alongside places-sheet). When active, a drag downward from
// the very top of the page pulls a spinner into view; releasing past the
// threshold refreshes the current page (Turbo Drive when present, a full
// reload otherwise). Below the threshold it springs back and nothing happens.
//
//   <body data-controller="places-sheet pull-to-refresh">
//
// The whole page (window) is the scroll container here — see _base.css — so we
// read window.scrollY to know when we're at the top, and translate a spinner
// element the controller injects into <body>.
declare global {
  interface Window {
    Turbo?: { visit: (location: string, options?: { action?: string }) => void }
  }
}

// Multiplier applied to finger travel so the pull feels weighted (rubber-band).
const RESISTANCE = 0.5
// Visual pull (px, after resistance) at which release triggers a refresh.
const TRIGGER_THRESHOLD = 64
// Cap on how far the indicator travels, so an aggressive drag doesn't fling it.
const MAX_PULL = 96

export default class PullToRefreshController extends Controller<HTMLElement> {
  private indicator: HTMLElement | null = null
  private spinner: HTMLElement | null = null

  private tracking = false
  private refreshing = false
  private startX = 0
  private startY = 0
  private pull = 0
  private frame = 0

  private readonly onTouchStart = (e: TouchEvent): void => this.handleStart(e)
  private readonly onTouchMove = (e: TouchEvent): void => this.handleMove(e)
  private readonly onTouchEnd = (): void => this.handleEnd()

  connect(): void {
    // Only take over the gesture where the platform doesn't provide it.
    if (!this.isStandalone()) return

    this.buildIndicator()
    window.addEventListener("touchstart", this.onTouchStart, { passive: true })
    // Non-passive: we preventDefault while actively pulling so the page's own
    // overscroll doesn't fight the indicator.
    window.addEventListener("touchmove", this.onTouchMove, { passive: false })
    window.addEventListener("touchend", this.onTouchEnd, { passive: true })
    window.addEventListener("touchcancel", this.onTouchEnd, { passive: true })
  }

  disconnect(): void {
    window.removeEventListener("touchstart", this.onTouchStart)
    window.removeEventListener("touchmove", this.onTouchMove)
    window.removeEventListener("touchend", this.onTouchEnd)
    window.removeEventListener("touchcancel", this.onTouchEnd)
    if (this.frame) cancelAnimationFrame(this.frame)
    this.indicator?.remove()
    this.indicator = null
    this.spinner = null
  }

  private handleStart(e: TouchEvent): void {
    // Start a pull only from the top of the page, with a single finger, and
    // not while a refresh is already in flight.
    if (this.refreshing || e.touches.length !== 1 || this.currentScrollY() > 0) return
    const touch = e.touches[0]
    this.tracking = true
    this.startX = touch.clientX
    this.startY = touch.clientY
    this.pull = 0
  }

  private handleMove(e: TouchEvent): void {
    if (!this.tracking) return
    const touch = e.touches[0]
    const dy = touch.clientY - this.startY
    const dx = touch.clientX - this.startX

    // Bail on upward scroll, a scroll that left the top, or a mostly-horizontal
    // gesture (e.g. a swipe) — let the page handle those normally.
    if (dy <= 0 || this.currentScrollY() > 0 || Math.abs(dx) > Math.abs(dy)) {
      this.reset()
      return
    }

    // We're committing to a pull: stop the page from scrolling/bouncing.
    e.preventDefault()
    this.pull = Math.min(dy * RESISTANCE, MAX_PULL)
    this.render()
  }

  private handleEnd(): void {
    if (!this.tracking) return
    if (this.pull >= TRIGGER_THRESHOLD) {
      this.refresh()
    } else {
      this.reset()
    }
  }

  private refresh(): void {
    this.refreshing = true
    this.tracking = false
    if (this.indicator) {
      this.indicator.classList.add("pull-to-refresh-indicator--animating")
      this.indicator.classList.remove("pull-to-refresh-indicator--armed")
      this.indicator.classList.add("pull-to-refresh-indicator--refreshing")
      this.indicator.style.transform = `translateY(${TRIGGER_THRESHOLD}px)`
      this.indicator.style.opacity = "1"
    }
    if (this.spinner) this.spinner.style.transform = ""

    const href = window.location.href
    if (window.Turbo) {
      window.Turbo.visit(href, { action: "replace" })
    } else {
      window.location.reload()
    }
  }

  private render(): void {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = 0
      const indicator = this.indicator
      const spinner = this.spinner
      if (!indicator || !spinner) return
      const progress = Math.min(this.pull / TRIGGER_THRESHOLD, 1)
      indicator.classList.remove("pull-to-refresh-indicator--animating")
      indicator.style.transform = `translateY(${this.pull}px)`
      indicator.style.opacity = String(progress)
      indicator.classList.toggle("pull-to-refresh-indicator--armed", this.pull >= TRIGGER_THRESHOLD)
      // Wind the spinner up as the pull deepens for tactile feedback.
      spinner.style.transform = `rotate(${progress * 270}deg)`
    })
  }

  // Spring the indicator back out of view and drop the gesture.
  private reset(): void {
    this.tracking = false
    this.pull = 0
    if (this.frame) {
      cancelAnimationFrame(this.frame)
      this.frame = 0
    }
    const indicator = this.indicator
    if (indicator) {
      indicator.classList.add("pull-to-refresh-indicator--animating")
      indicator.classList.remove("pull-to-refresh-indicator--armed")
      indicator.style.transform = ""
      indicator.style.opacity = "0"
    }
    if (this.spinner) this.spinner.style.transform = ""
  }

  private buildIndicator(): void {
    if (this.indicator) return
    const indicator = document.createElement("div")
    indicator.className = "pull-to-refresh-indicator"
    indicator.setAttribute("aria-hidden", "true")
    const spinner = document.createElement("span")
    spinner.className = "pull-to-refresh-spinner"
    indicator.appendChild(spinner)
    document.body.appendChild(indicator)
    this.indicator = indicator
    this.spinner = spinner
  }

  private currentScrollY(): number {
    // Clamp iOS rubber-band overscroll, matching auto-hide-header.
    return Math.max(0, window.scrollY)
  }

  private isStandalone(): boolean {
    const media =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(display-mode: standalone), (display-mode: fullscreen), (display-mode: minimal-ui)").matches
    // iOS Safari predates display-mode and exposes navigator.standalone instead.
    const iosStandalone = (window.navigator as Navigator & { standalone?: boolean }).standalone === true
    return media || iosStandalone
  }
}
