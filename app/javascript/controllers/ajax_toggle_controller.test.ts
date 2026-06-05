import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import AjaxToggleController from "./ajax_toggle_controller"

describe("AjaxToggleController", () => {
  let application: Application
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    document.head.innerHTML = `<meta name="csrf-token" content="csrf-test-token">`
    application = Application.start()
    application.register("ajax-toggle", AjaxToggleController)
    fetchSpy = vi.spyOn(global, "fetch")
  })

  afterEach(() => {
    application.stop()
    fetchSpy.mockRestore()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  async function mount(opts: {
    url: string
    altUrl: string
    altHtml: string
    initialHtml: string
    className?: string
    altClass?: string
  }) {
    const className = opts.className ?? ""
    const altClass = opts.altClass ?? ""
    document.body.innerHTML = `
      <button class="${className}"
              data-controller="ajax-toggle"
              data-action="click->ajax-toggle#toggle"
              data-ajax-toggle-url-value="${opts.url}"
              data-ajax-toggle-alt-url-value="${opts.altUrl}"
              data-ajax-toggle-alt-html-value="${opts.altHtml}"
              data-ajax-toggle-alt-class-value="${altClass}">
        ${opts.initialHtml}
      </button>
    `
    // Let Stimulus' MutationObserver pick up the controller before returning.
    await new Promise((resolve) => setTimeout(resolve, 0))
    return document.querySelector("button") as HTMLButtonElement
  }

  function flushMicrotasks(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0))
  }

  it("POSTs to the current url and swaps to the alt state on success", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 200 }))
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
    })

    btn.click()
    await flushMicrotasks()

    expect(fetchSpy).toHaveBeenCalledOnce()
    const [calledUrl, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(calledUrl).toBe("/add")
    expect(init.method).toBe("POST")
    expect((init.headers as Record<string, string>)["X-CSRF-Token"]).toBe("csrf-test-token")

    expect(btn.textContent?.trim()).toBe("Remove")
    expect(btn.dataset.ajaxToggleUrlValue).toBe("/remove")
    expect(btn.dataset.ajaxToggleAltUrlValue).toBe("/add")
    expect(btn.dataset.ajaxToggleAltHtmlValue?.trim()).toBe("Add")
  })

  it("toggles back when clicked twice", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 200 }))
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
    })

    btn.click()
    await flushMicrotasks()
    expect(btn.textContent?.trim()).toBe("Remove")

    btn.click()
    await flushMicrotasks()
    expect(btn.textContent?.trim()).toBe("Add")
    expect(fetchSpy.mock.calls[1]?.[0]).toBe("/remove")
  })

  it("leaves the button unchanged when the request fails", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 422 }))
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
    })

    btn.click()
    await flushMicrotasks()

    expect(btn.textContent?.trim()).toBe("Add")
    expect(btn.dataset.ajaxToggleUrlValue).toBe("/add")
    expect(btn.disabled).toBe(false)
  })

  it("swaps the button's className when alt-class is set", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 200 }))
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
      className: "pulse-action-btn",
      altClass: "pulse-action-btn-secondary",
    })

    btn.click()
    await flushMicrotasks()
    expect(btn.className).toBe("pulse-action-btn-secondary")
    expect(btn.dataset.ajaxToggleAltClassValue).toBe("pulse-action-btn")

    btn.click()
    await flushMicrotasks()
    expect(btn.className).toBe("pulse-action-btn")
    expect(btn.dataset.ajaxToggleAltClassValue).toBe("pulse-action-btn-secondary")
  })

  it("leaves className alone when alt-class is empty", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 200 }))
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
      className: "pulse-action-btn-secondary",
      altClass: "",
    })

    btn.click()
    await flushMicrotasks()
    expect(btn.className).toBe("pulse-action-btn-secondary")
  })

  it("ignores repeat clicks while a request is in flight", async () => {
    let resolveFetch!: (response: Response) => void
    fetchSpy.mockImplementation(
      () => new Promise<Response>((resolve) => { resolveFetch = resolve })
    )
    const btn = await mount({
      url: "/add",
      altUrl: "/remove",
      altHtml: "Remove",
      initialHtml: "Add",
    })

    btn.click()
    btn.click()
    btn.click()
    expect(fetchSpy).toHaveBeenCalledOnce()

    resolveFetch(new Response("", { status: 200 }))
    await flushMicrotasks()
    expect(btn.textContent?.trim()).toBe("Remove")
  })
})
