import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CardExpandController from "./card_expand_controller"

describe("CardExpandController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("card-expand", CardExpandController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  function mount({ overflows }: { overflows: boolean }) {
    document.body.innerHTML = `
      <div data-controller="card-expand" class="pulse-feed-item-content">
        <div data-card-expand-target="body" class="pulse-feed-item-content-clamped">body html here</div>
        <button data-card-expand-target="toggle"
                data-action="click->card-expand#toggle"
                data-no-navigate aria-expanded="false" hidden>Show more</button>
      </div>
    `
    const body = document.querySelector(
      "[data-card-expand-target='body']",
    ) as HTMLElement
    // jsdom doesn't lay out CSS, so scrollHeight/clientHeight both default to
    // 0. Stub them so connect() sees the overflow condition we want to test.
    Object.defineProperty(body, "scrollHeight", {
      configurable: true,
      get: () => (overflows ? 200 : 50),
    })
    Object.defineProperty(body, "clientHeight", {
      configurable: true,
      get: () => 100,
    })
  }

  function body(): HTMLElement {
    return document.querySelector(
      "[data-card-expand-target='body']",
    ) as HTMLElement
  }

  function toggle(): HTMLButtonElement {
    return document.querySelector(
      "[data-card-expand-target='toggle']",
    ) as HTMLButtonElement
  }

  it("unhides the toggle button when the clamped body overflows", async () => {
    mount({ overflows: true })
    await vi.waitFor(() => expect(toggle().hidden).toBe(false))
  })

  it("keeps the toggle button hidden when the body fits inside the clamp", async () => {
    mount({ overflows: false })
    // Give Stimulus a tick to wire connect().
    await new Promise((r) => setTimeout(r, 0))
    expect(toggle().hidden).toBe(true)
  })

  it("clicking the toggle removes the clamp class and swaps to 'Show less'", async () => {
    mount({ overflows: true })
    await vi.waitFor(() => expect(toggle().hidden).toBe(false))

    toggle().click()
    expect(body().classList.contains("pulse-feed-item-content-clamped")).toBe(false)
    expect(toggle().textContent).toBe("Show less")
    expect(toggle().getAttribute("aria-expanded")).toBe("true")

    toggle().click()
    expect(body().classList.contains("pulse-feed-item-content-clamped")).toBe(true)
    expect(toggle().textContent).toBe("Show more")
    expect(toggle().getAttribute("aria-expanded")).toBe("false")
  })

  it("toggle click does not propagate (the parent card-navigate handler won't fire)", async () => {
    mount({ overflows: true })
    await vi.waitFor(() => expect(toggle().hidden).toBe(false))

    const parentClick = vi.fn()
    document
      .querySelector("[data-controller='card-expand']")!
      .addEventListener("click", parentClick)

    toggle().click()
    expect(parentClick).not.toHaveBeenCalled()
  })

  it("declares data-no-navigate on the toggle so card-navigate (bug 4) skips it", () => {
    mount({ overflows: false })
    expect(toggle().hasAttribute("data-no-navigate")).toBe(true)
  })
})
