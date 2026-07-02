import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import WebPushController from "./web_push_controller"

describe("WebPushController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("web-push", WebPushController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    delete (window.navigator as unknown as Record<string, unknown>).serviceWorker
    delete (window as unknown as Record<string, unknown>).PushManager
    delete (window as unknown as Record<string, unknown>).Notification
  })

  function stubPushSupport(subscription: { endpoint: string } | null): void {
    const registration = {
      pushManager: {
        getSubscription: async () => subscription,
      },
    }
    Object.defineProperty(window.navigator, "serviceWorker", {
      value: { getRegistration: async () => registration },
      configurable: true,
    })
    ;(window as unknown as Record<string, unknown>).PushManager = function PushManager() {}
    ;(window as unknown as Record<string, unknown>).Notification = { permission: "default" }
  }

  // The hidden attribute is defeated by Pulse's explicit display rules
  // (.pulse-action-btn / .pulse-badge are inline-flex, and author CSS beats
  // the UA [hidden] rule), so visibility is toggled via style.display.
  async function mount(): Promise<{ button: HTMLButtonElement; status: HTMLElement; badges: HTMLElement[] }> {
    document.body.innerHTML = `
      <div data-controller="web-push" data-web-push-url-value="/u/ada/settings/push-subscriptions">
        <button data-web-push-target="button">Enable on this device</button>
        <p data-web-push-target="status" hidden></p>
        <span data-web-push-target="badge" data-endpoint="https://push.example.com/send/this-one" style="display: none;">This device</span>
        <span data-web-push-target="badge" data-endpoint="https://push.example.com/send/other" style="display: none;">This device</span>
      </div>
    `
    // Let Stimulus connect and the async subscription check settle.
    await new Promise((resolve) => setTimeout(resolve, 0))
    await new Promise((resolve) => setTimeout(resolve, 0))
    return {
      button: document.querySelector("button") as HTMLButtonElement,
      status: document.querySelector('[data-web-push-target="status"]') as HTMLElement,
      badges: [...document.querySelectorAll('[data-web-push-target="badge"]')] as HTMLElement[],
    }
  }

  it("hides the subscribe button and badges the matching device when this browser is already subscribed", async () => {
    stubPushSupport({ endpoint: "https://push.example.com/send/this-one" })

    const { button, status, badges } = await mount()

    expect(button.style.display).toBe("none")
    expect(status.hidden).toBe(false)
    expect(status.textContent).toMatch(/enabled on this device/i)
    expect(badges[0].style.display).not.toBe("none")
    expect(badges[1].style.display).toBe("none")
  })

  it("leaves the button when the browser subscription is unknown to the server", async () => {
    // e.g. the row was revoked from another device: the browser still holds a
    // PushSubscription, but no active server row matches. Re-subscribing
    // (button click) upserts and repairs the row, so the button must stay.
    stubPushSupport({ endpoint: "https://push.example.com/send/revoked-elsewhere" })

    const { button, status } = await mount()

    expect(button.style.display).not.toBe("none")
    expect(status.hidden).toBe(true)
  })

  it("leaves the subscribe button visible when this browser has no subscription", async () => {
    stubPushSupport(null)

    const { button, status, badges } = await mount()

    expect(button.style.display).not.toBe("none")
    expect(status.hidden).toBe(true)
    expect(badges.every((badge) => badge.style.display === "none")).toBe(true)
  })

  it("hides the button and shows guidance when push is unsupported", async () => {
    // No stub: jsdom has no serviceWorker.
    const { button, status } = await mount()

    expect(button.style.display).toBe("none")
    expect(status.hidden).toBe(false)
    expect(status.textContent).toMatch(/home screen/i)
  })
})
