import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import AutoHideHeaderController from "./auto_hide_header_controller"

const HIDDEN_CLASS = "pulse-top-header--hidden"

describe("AutoHideHeaderController", () => {
  let application: Application
  let header: HTMLElement

  // The controller coalesces scroll handling through requestAnimationFrame;
  // run the callback synchronously so scroll events resolve within the test.
  beforeEach(() => {
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback): number => {
      cb(0)
      return 0
    })
    application = Application.start()
    application.register("auto-hide-header", AutoHideHeaderController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    setScroll(0)
    vi.unstubAllGlobals()
  })

  function setScroll(y: number): void {
    Object.defineProperty(window, "scrollY", { value: y, configurable: true })
  }

  async function mount(): Promise<void> {
    document.body.innerHTML = `
      <header class="pulse-top-header"
              data-controller="auto-hide-header"
              data-auto-hide-header-hidden-class="${HIDDEN_CLASS}">Header</header>
      <div style="height: 5000px">tall content</div>
    `
    header = document.querySelector(".pulse-top-header") as HTMLElement
    // Give the header a measurable height so the "near top" band is exercised.
    Object.defineProperty(header, "offsetHeight", { value: 56, configurable: true })
    await new Promise((r) => setTimeout(r, 0))
  }

  function scrollTo(y: number): void {
    setScroll(y)
    window.dispatchEvent(new Event("scroll"))
  }

  it("hides the header when scrolling down past the threshold", async () => {
    await mount()
    scrollTo(400)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(true)
  })

  it("reveals the header when scrolling back up past the threshold", async () => {
    await mount()
    scrollTo(400)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(true)
    scrollTo(300)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(false)
  })

  it("always reveals the header near the top of the page", async () => {
    await mount()
    scrollTo(400)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(true)
    // Within the header's own height of the top: force-reveal regardless of direction.
    scrollTo(20)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(false)
  })

  it("ignores scroll deltas smaller than the threshold", async () => {
    await mount()
    scrollTo(400)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(true)
    // A tiny upward nudge should not flip the state.
    scrollTo(397)
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(true)
  })

  it("starts revealed even if a cached snapshot restored the hidden class", async () => {
    document.body.innerHTML = `
      <header class="pulse-top-header ${HIDDEN_CLASS}"
              data-controller="auto-hide-header"
              data-auto-hide-header-hidden-class="${HIDDEN_CLASS}">Header</header>
    `
    await new Promise((r) => setTimeout(r, 0))
    const restored = document.querySelector(".pulse-top-header") as HTMLElement
    expect(restored.classList.contains(HIDDEN_CLASS)).toBe(false)
  })

  it("reveals the header when a descendant receives focus", async () => {
    document.body.innerHTML = `
      <header class="pulse-top-header ${HIDDEN_CLASS}"
              data-controller="auto-hide-header"
              data-auto-hide-header-hidden-class="${HIDDEN_CLASS}">
        <input id="search" />
      </header>
    `
    header = document.querySelector(".pulse-top-header") as HTMLElement
    await new Promise((r) => setTimeout(r, 0))
    // Simulate the header hidden after a scroll, then focus lands inside it.
    header.classList.add(HIDDEN_CLASS)
    header.dispatchEvent(new FocusEvent("focusin", { bubbles: true }))
    expect(header.classList.contains(HIDDEN_CLASS)).toBe(false)
  })
})
