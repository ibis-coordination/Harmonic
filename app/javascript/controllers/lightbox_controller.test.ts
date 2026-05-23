import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import LightboxController from "./lightbox_controller"

describe("LightboxController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("lightbox", LightboxController)
  })

  afterEach(() => {
    // Application.start() in beforeEach creates a new Stimulus app per
    // test; stop the prior one or controllers from earlier tests keep
    // observing the document and double-handle clicks.
    application.stop()
    document.querySelectorAll(".lightbox-backdrop").forEach((el) => el.remove())
    document.body.style.overflow = ""
    document.body.innerHTML = ""
  })

  async function render(triggers: Array<{ url: string; alt?: string; caption?: string }>) {
    const html = triggers
      .map(
        (t, i) => `
          <button
            data-lightbox-target="trigger"
            data-action="click->lightbox#open"
            data-lightbox-large-url-param="${t.url}"
            data-lightbox-alt-param="${t.alt || ""}"
            data-lightbox-caption-param="${t.caption || ""}"
            data-trigger-index="${i}"
          >open ${i}</button>
        `,
      )
      .join("")
    document.body.innerHTML = `<div data-controller="lightbox">${html}</div>`
    // Stimulus uses MutationObserver to detect controller elements; the
    // observer fires on the next microtask, not synchronously.
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  it("renders a backdrop with the large image when a trigger is clicked", async () => {
    await render([{ url: "/img/a.webp", alt: "A photo" }])
    const trigger = document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!
    trigger.click()

    const backdrop = document.querySelector<HTMLDivElement>(".lightbox-backdrop")
    expect(backdrop).not.toBeNull()
    const img = backdrop!.querySelector<HTMLImageElement>(".lightbox-img")
    expect(img).not.toBeNull()
    expect(img!.src).toContain("/img/a.webp")
    expect(img!.alt).toBe("A photo")
  })

  it("renders a caption when one is provided", async () => {
    await render([{ url: "/img/a.webp", caption: "Hello" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()

    const caption = document.querySelector(".lightbox-caption")
    expect(caption).not.toBeNull()
    expect(caption!.textContent).toBe("Hello")
  })

  it("omits the caption element when caption is blank or whitespace", async () => {
    await render([{ url: "/img/a.webp", caption: "  " }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()

    expect(document.querySelector(".lightbox-caption")).toBeNull()
  })

  it("does nothing when the trigger has no url param", async () => {
    await render([{ url: "" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()

    expect(document.querySelector(".lightbox-backdrop")).toBeNull()
  })

  it("closes when the close button is clicked", async () => {
    await render([{ url: "/img/a.webp" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()
    expect(document.querySelector(".lightbox-backdrop")).not.toBeNull()

    document.querySelector<HTMLButtonElement>(".lightbox-close")!.click()
    expect(document.querySelector(".lightbox-backdrop")).toBeNull()
  })

  it("closes when the backdrop itself is clicked (not the image)", async () => {
    await render([{ url: "/img/a.webp" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()

    const backdrop = document.querySelector<HTMLDivElement>(".lightbox-backdrop")!
    backdrop.dispatchEvent(new MouseEvent("click", { bubbles: true }))
    // dispatching with target=backdrop itself by virtue of being the listener element.
    // The implementation checks event.target === backdrop; simulate that:
    Object.defineProperty(Event.prototype, "target", { configurable: true })
    expect(document.querySelector(".lightbox-backdrop")).toBeNull()
  })

  it("does NOT close when the image (inside backdrop) is clicked", async () => {
    await render([{ url: "/img/a.webp" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()

    const img = document.querySelector<HTMLImageElement>(".lightbox-img")!
    img.click() // bubbles to backdrop, but event.target is img, not backdrop
    expect(document.querySelector(".lightbox-backdrop")).not.toBeNull()
  })

  it("closes on Escape keypress", async () => {
    await render([{ url: "/img/a.webp" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()
    expect(document.querySelector(".lightbox-backdrop")).not.toBeNull()

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))
    expect(document.querySelector(".lightbox-backdrop")).toBeNull()
  })

  it("opening a second trigger replaces the first backdrop", async () => {
    await render([
      { url: "/img/a.webp", alt: "A" },
      { url: "/img/b.webp", alt: "B" },
    ])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()
    document.querySelector<HTMLButtonElement>("[data-trigger-index='1']")!.click()

    const backdrops = document.querySelectorAll(".lightbox-backdrop")
    expect(backdrops.length).toBe(1)
    expect(backdrops[0].querySelector<HTMLImageElement>(".lightbox-img")!.alt).toBe("B")
  })

  it("disables body scroll while open and restores on close", async () => {
    await render([{ url: "/img/a.webp" }])
    document.querySelector<HTMLButtonElement>("[data-trigger-index='0']")!.click()
    expect(document.body.style.overflow).toBe("hidden")

    document.querySelector<HTMLButtonElement>(".lightbox-close")!.click()
    expect(document.body.style.overflow).toBe("")
  })
})
