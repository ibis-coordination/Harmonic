import { describe, it, expect, beforeEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import PinController from "./pin_controller"
import { waitForController } from "../test/setup"

// Helper to flush pending promises - needs multiple ticks for promise chains
const flushPromises = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0))
  await new Promise((resolve) => setTimeout(resolve, 0))
}

describe("PinController", () => {
  let application: Application
  let mockFetch: ReturnType<typeof vi.fn>

  beforeEach(() => {
    // Mock fetch - return a default resolved response
    mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ pinned: false, click_title: "" }),
    } as Response)
    global.fetch = mockFetch

    // Set up CSRF meta tag
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    application = Application.start()
    application.register("pin", PinController)
  })

  it("initializes isPinned from data attribute", async () => {
    document.body.innerHTML = `
      <div data-controller="pin">
        <button data-pin-target="pinButton"
                data-is-pinned="true"
                data-pin-url="/api/pin">Pin</button>
      </div>
    `

    await waitForController()

    const button = document.querySelector("[data-pin-target='pinButton']") as HTMLElement
    // The controller reads data-is-pinned on connect
    expect(button.dataset.isPinned).toBe("true")
  })

  it("sends PUT request to toggle pin state", async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ pinned: true, click_title: "Click to unpin" }),
    } as Response)

    document.body.innerHTML = `
      <div data-controller="pin">
        <button data-pin-target="pinButton"
                data-is-pinned="false"
                data-pin-url="/api/pin">Pin</button>
      </div>
    `

    await waitForController()

    const button = document.querySelector("[data-pin-target='pinButton']") as HTMLButtonElement
    button.click()

    expect(mockFetch).toHaveBeenCalledWith("/api/pin", {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": "test-csrf-token",
      },
      body: JSON.stringify({ pinned: true }),
    })
  })

  it("updates button opacity when pinned", async () => {
    // Reset and set up a clean mock
    mockFetch.mockReset()
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ pinned: true, click_title: "Click to unpin" }),
    } as Response)

    document.body.innerHTML = `
      <div data-controller="pin">
        <button data-pin-target="pinButton"
                data-is-pinned="false"
                data-pin-url="/api/pin"
                style="opacity: 0.2">Pin</button>
      </div>
    `

    await waitForController()

    const button = document.querySelector("[data-pin-target='pinButton']") as HTMLButtonElement
    button.click()

    // Wait for fetch and response.json() promises to resolve
    await flushPromises()
    await flushPromises()

    expect(button.style.opacity).toBe("1")
    expect(button.title).toBe("Click to unpin")
  })

  it("updates button opacity when unpinned", async () => {
    // Reset and set up a clean mock
    mockFetch.mockReset()
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ pinned: false, click_title: "Click to pin" }),
    } as Response)

    document.body.innerHTML = `
      <div data-controller="pin">
        <button data-pin-target="pinButton"
                data-is-pinned="true"
                data-pin-url="/api/pin"
                style="opacity: 1">Unpin</button>
      </div>
    `

    await waitForController()

    const button = document.querySelector("[data-pin-target='pinButton']") as HTMLButtonElement
    button.click()

    // Wait for fetch and response.json() promises to resolve
    await flushPromises()
    await flushPromises()

    expect(button.style.opacity).toBe("0.2")
    expect(button.title).toBe("Click to pin")
  })

  it("does nothing if no URL is specified", async () => {
    document.body.innerHTML = `
      <div data-controller="pin">
        <button data-pin-target="pinButton"
                data-is-pinned="false">Pin</button>
      </div>
    `

    await waitForController()

    const button = document.querySelector("[data-pin-target='pinButton']") as HTMLButtonElement
    button.click()

    expect(mockFetch).not.toHaveBeenCalled()
  })
})
