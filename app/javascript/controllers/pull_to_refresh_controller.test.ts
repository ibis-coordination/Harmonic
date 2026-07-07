import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import PullToRefreshController from "./pull_to_refresh_controller"

// A pull is finger travel; the controller applies RESISTANCE=0.5 and triggers at
// a 64px *pulled* distance, so ~128px+ of finger travel arms the refresh.
function touch(type: string, clientX: number, clientY: number): Event {
  const e = new Event(type, { bubbles: true, cancelable: true })
  const point = { clientX, clientY }
  Object.assign(e, { touches: [point], changedTouches: [point] })
  return e
}

describe("PullToRefreshController", () => {
  let application: Application
  let element: HTMLElement
  let visit: ReturnType<typeof vi.fn>

  function setStandalone(standalone: boolean): void {
    window.matchMedia = vi.fn().mockReturnValue({ matches: standalone }) as unknown as typeof window.matchMedia
  }

  // Mount on a child element (not <body>) so removing it in teardown reliably
  // fires disconnect() and unhooks the window listeners between tests.
  async function mount(): Promise<void> {
    element = document.createElement("div")
    element.setAttribute("data-controller", "pull-to-refresh")
    document.body.appendChild(element)
    await new Promise((r) => setTimeout(r, 0))
  }

  function pull(fromY: number, toY: number): void {
    window.dispatchEvent(touch("touchstart", 100, fromY))
    window.dispatchEvent(touch("touchmove", 100, toY))
    window.dispatchEvent(touch("touchend", 100, toY))
  }

  beforeAll(() => {
    application = Application.start()
    application.register("pull-to-refresh", PullToRefreshController)
  })

  afterAll(() => {
    application.stop()
  })

  beforeEach(() => {
    visit = vi.fn()
    window.Turbo = { visit } as unknown as typeof window.Turbo
    vi.stubGlobal("requestAnimationFrame", () => 1)
    vi.stubGlobal("cancelAnimationFrame", () => {})
  })

  afterEach(async () => {
    element?.remove()
    // Let Stimulus observe the removal and run disconnect().
    await new Promise((r) => setTimeout(r, 0))
    document.body.innerHTML = ""
    delete window.Turbo
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("does nothing outside a standalone PWA", async () => {
    setStandalone(false)
    await mount()
    expect(document.querySelector(".pull-to-refresh-indicator")).toBeNull()
    pull(10, 300)
    expect(visit).not.toHaveBeenCalled()
  })

  it("injects the indicator when running as a standalone PWA", async () => {
    setStandalone(true)
    await mount()
    expect(document.querySelector(".pull-to-refresh-indicator")).not.toBeNull()
  })

  it("refreshes via Turbo when pulled past the threshold and released", async () => {
    setStandalone(true)
    await mount()
    pull(10, 300) // 290px travel → ~96px pull, well past the 64px trigger
    expect(visit).toHaveBeenCalledTimes(1)
    expect(visit).toHaveBeenCalledWith(window.location.href, { action: "replace" })
  })

  it("does not refresh when the pull is too short", async () => {
    setStandalone(true)
    await mount()
    pull(10, 90) // 80px travel → 40px pull, below the 64px trigger
    expect(visit).not.toHaveBeenCalled()
  })

  it("ignores a mostly-horizontal swipe", async () => {
    setStandalone(true)
    await mount()
    window.dispatchEvent(touch("touchstart", 100, 10))
    window.dispatchEvent(touch("touchmove", 400, 60)) // dx 300 > dy 50
    window.dispatchEvent(touch("touchend", 400, 60))
    expect(visit).not.toHaveBeenCalled()
  })

  it("falls back to a full reload when Turbo is absent", async () => {
    delete window.Turbo
    const reload = vi.fn()
    Object.defineProperty(window, "location", {
      value: { ...window.location, href: "https://example.test/", reload },
      configurable: true,
      writable: true,
    })
    setStandalone(true)
    await mount()
    pull(10, 300)
    expect(reload).toHaveBeenCalledTimes(1)
  })

  it("removes the indicator on disconnect", async () => {
    setStandalone(true)
    await mount()
    expect(document.querySelector(".pull-to-refresh-indicator")).not.toBeNull()
    element.remove()
    await new Promise((r) => setTimeout(r, 0))
    expect(document.querySelector(".pull-to-refresh-indicator")).toBeNull()
  })
})
