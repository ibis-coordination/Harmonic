import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from "vitest"
import { Application } from "@hotwired/stimulus"
import LogoutController from "./logout_controller"

describe("LogoutController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("logout", LogoutController)
  })

  afterEach(() => {
    vi.useRealTimers()
    application.stop()
    document.body.innerHTML = ""
    delete (window.navigator as unknown as Record<string, unknown>).serviceWorker
  })

  function stubPush(subscription: { endpoint: string; unsubscribe: Mock } | null): void {
    Object.defineProperty(window.navigator, "serviceWorker", {
      value: {
        getRegistration: async () => ({
          pushManager: { getSubscription: async () => subscription },
        }),
      },
      configurable: true,
    })
  }

  async function mount(): Promise<{ form: HTMLFormElement; field: HTMLInputElement; requestSubmit: Mock }> {
    document.body.innerHTML = `
      <form action="/logout" method="post" data-controller="logout" data-action="submit->logout#prepare">
        <input type="hidden" name="push_endpoint" value="">
        <button type="submit">Sign Out</button>
      </form>
    `
    // Let Stimulus connect.
    await new Promise((resolve) => setTimeout(resolve, 0))
    const form = document.querySelector("form") as HTMLFormElement
    // jsdom doesn't implement real form submission; the controller resubmits
    // via requestSubmit, so observe that.
    const requestSubmit = vi.fn()
    form.requestSubmit = requestSubmit
    return {
      form,
      field: form.querySelector('input[name="push_endpoint"]') as HTMLInputElement,
      requestSubmit,
    }
  }

  // Returns false when the controller called preventDefault (intercepted).
  function submit(form: HTMLFormElement): boolean {
    return form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
  }

  async function settle(): Promise<void> {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0))
  }

  it("unsubscribes and reports this browser's endpoint before the logout request", async () => {
    const unsubscribe = vi.fn(async () => true)
    stubPush({ endpoint: "https://push.example.com/send/here", unsubscribe })
    const { form, field, requestSubmit } = await mount()

    const proceeded = submit(form)
    expect(proceeded).toBe(false)
    await settle()

    expect(field.value).toBe("https://push.example.com/send/here")
    expect(unsubscribe).toHaveBeenCalled()
    expect(requestSubmit).toHaveBeenCalled()
  })

  it("resubmits without re-running cleanup", async () => {
    const unsubscribe = vi.fn(async () => true)
    stubPush({ endpoint: "https://push.example.com/send/here", unsubscribe })
    const { form } = await mount()

    submit(form)
    await settle()

    // In a real browser requestSubmit dispatches submit again; that second
    // pass must go straight through to the server.
    const proceeded = submit(form)
    expect(proceeded).toBe(true)
    expect(unsubscribe).toHaveBeenCalledTimes(1)
  })

  it("lets logout proceed untouched when the browser has no service worker support", async () => {
    // No stub: jsdom has no serviceWorker.
    const { form, requestSubmit } = await mount()

    const proceeded = submit(form)
    await settle()

    expect(proceeded).toBe(true)
    expect(requestSubmit).not.toHaveBeenCalled()
  })

  it("resubmits with an empty endpoint when this browser has no subscription", async () => {
    stubPush(null)
    const { form, field, requestSubmit } = await mount()

    submit(form)
    await settle()

    expect(field.value).toBe("")
    expect(requestSubmit).toHaveBeenCalled()
  })

  it("still logs out when the push lookup fails", async () => {
    Object.defineProperty(window.navigator, "serviceWorker", {
      value: {
        getRegistration: async () => {
          throw new Error("boom")
        },
      },
      configurable: true,
    })
    const { form, field, requestSubmit } = await mount()

    submit(form)
    await settle()

    expect(field.value).toBe("")
    expect(requestSubmit).toHaveBeenCalled()
  })

  it("gives up on push cleanup after a timeout so logout can't hang", async () => {
    Object.defineProperty(window.navigator, "serviceWorker", {
      value: { getRegistration: () => new Promise(() => {}) },
      configurable: true,
    })
    const { form, requestSubmit } = await mount()
    vi.useFakeTimers()

    submit(form)
    await vi.advanceTimersByTimeAsync(5000)

    expect(requestSubmit).toHaveBeenCalled()
  })
})
