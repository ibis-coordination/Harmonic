import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CooldownButtonController from "./cooldown_button_controller"

describe("CooldownButtonController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()
    application = Application.start()
    application.register("cooldown-button", CooldownButtonController)
  })

  afterEach(() => {
    vi.useRealTimers()
    application.stop()
    document.body.innerHTML = ""
  })

  function mount(seconds: number, buttonDisabled = true) {
    document.body.innerHTML = `
      <div data-controller="cooldown-button" data-cooldown-button-seconds-value="${seconds}">
        <form action="/x" method="post">
          <button type="submit" ${buttonDisabled ? "disabled" : ""}>Resend</button>
        </form>
        <p data-cooldown-button-target="countdown">
          Available in <span data-cooldown-button-target="countdownNumber">${seconds}</span>s
        </p>
      </div>
    `
  }

  function button(): HTMLButtonElement {
    return document.querySelector("button") as HTMLButtonElement
  }

  function countdown(): HTMLElement {
    return document.querySelector(
      "[data-cooldown-button-target='countdown']",
    ) as HTMLElement
  }

  function countdownNumber(): HTMLElement {
    return document.querySelector(
      "[data-cooldown-button-target='countdownNumber']",
    ) as HTMLElement
  }

  it("decrements only the number span (surrounding text is stable)", async () => {
    mount(3)
    expect(countdownNumber().textContent).toBe("3")
    expect(button().disabled).toBe(true)

    await vi.advanceTimersByTimeAsync(1000)
    expect(countdownNumber().textContent).toBe("2")
    expect(button().disabled).toBe(true)

    await vi.advanceTimersByTimeAsync(1000)
    expect(countdownNumber().textContent).toBe("1")
    expect(button().disabled).toBe(true)
  })

  it("does not touch the surrounding 'Available in … s' text while ticking", async () => {
    mount(3)
    // Sibling text nodes should be untouched so the layout doesn't reflow
    // beyond what the fixed-width number-span span allows.
    const wholeText = () => countdown().textContent?.replace(/\s+/g, " ").trim()
    expect(wholeText()).toBe("Available in 3s")

    await vi.advanceTimersByTimeAsync(1000)
    expect(wholeText()).toBe("Available in 2s")
  })

  it("re-enables the button and hides the countdown when it hits zero", async () => {
    mount(2)
    await vi.advanceTimersByTimeAsync(2000)

    expect(button().disabled).toBe(false)
    expect(countdown().style.display).toBe("none")
  })

  it("immediately enables the button when the rendered value is already zero", async () => {
    // Server-side race: by the time the page rendered the cooldown had
    // already elapsed. Don't leave the button stuck in disabled.
    mount(0, /* buttonDisabled */ true)
    // Stimulus's MutationObserver fires asynchronously; let connect() run.
    await vi.waitFor(() => expect(button().disabled).toBe(false))
    expect(countdown().style.display).toBe("none")
  })

  it("stops ticking after enabling", async () => {
    mount(1)
    await vi.advanceTimersByTimeAsync(1000)
    expect(button().disabled).toBe(false)

    // Number span keeps its last value (we don't touch it after enable),
    // but the parent is hidden so users don't see it. Just verify no further
    // ticks happen.
    const lastNum = countdownNumber().textContent
    await vi.advanceTimersByTimeAsync(5000)
    expect(countdownNumber().textContent).toBe(lastNum)
  })
})
