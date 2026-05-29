import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from "vitest"
import { Application } from "@hotwired/stimulus"
import CardNavigateController from "./card_navigate_controller"

describe("CardNavigateController", () => {
  let application: Application
  let assignSpy: Mock<(href: string) => void>
  let openSpy: Mock<(url: string, target: string, features?: string) => Window | null>

  beforeEach(() => {
    application = Application.start()
    application.register("card-navigate", CardNavigateController)

    // jsdom's window.location is read-only; intercept via a property
    // descriptor that records every write to href.
    assignSpy = vi.fn<(href: string) => void>()
    Object.defineProperty(window, "location", {
      configurable: true,
      value: new Proxy(
        { href: "" },
        {
          set(target, prop, value) {
            if (prop === "href") assignSpy(value)
            ;(target as Record<string | symbol, unknown>)[prop] = value
            return true
          },
        },
      ),
    })

    // Spy on window.open so modifier-click and middle-click can assert
    // a new-tab open instead of (or in addition to) navigation.
    openSpy = vi.fn<(url: string, target: string, features?: string) => Window | null>(() => null)
    window.open = openSpy as unknown as typeof window.open
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  async function mount(extraInnerHtml = "") {
    document.body.innerHTML = `
      <article data-controller="card-navigate"
               data-card-navigate-url-value="/n/abc12345"
               data-action="click->card-navigate#navigate auxclick->card-navigate#navigate keydown->card-navigate#keydown"
               role="link" tabindex="0">
        <div class="card-body">plain body text</div>
        <a href="/somewhere-else" class="link">A link</a>
        <button type="button" class="btn">A button</button>
        <button type="button" data-no-navigate class="opted-out">Opted out</button>
        ${extraInnerHtml}
      </article>
    `
    // Stimulus wires data-action asynchronously via its MutationObserver;
    // wait a tick so the handlers are bound before the test fires events.
    await new Promise((r) => setTimeout(r, 0))
  }

  function $(sel: string): HTMLElement {
    return document.querySelector(sel) as HTMLElement
  }

  it("clicking the plain body navigates to the URL value", async () => {
    await mount()
    $(".card-body").click()
    expect(assignSpy).toHaveBeenCalledWith("/n/abc12345")
  })

  it("clicking an anchor child does NOT trigger navigation (the anchor handles its own click)", async () => {
    await mount()
    $(".link").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("clicking a button child does NOT trigger navigation", async () => {
    await mount()
    $(".btn").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("clicking an element with data-no-navigate does NOT navigate", async () => {
    await mount()
    $(".opted-out").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("clicking inside a nested element under data-no-navigate also opts out", async () => {
    await mount(`<div data-no-navigate><span class="nested">deep</span></div>`)
    $(".nested").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("clicking inside an interactive child (text inside button) opts out", async () => {
    await mount(`<button type="button" class="outer"><span class="inner">click me</span></button>`)
    $(".inner").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("clicking inside a <summary> (disclosure widget) opts out", async () => {
    await mount(`<details><summary class="sum">click me</summary>body</details>`)
    $(".sum").click()
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("cmd-click opens the URL in a new tab via window.open, NOT in the current tab", async () => {
    await mount()
    $(".card-body").dispatchEvent(new MouseEvent("click", { bubbles: true, metaKey: true }))
    expect(assignSpy).not.toHaveBeenCalled()
    expect(openSpy).toHaveBeenCalledWith("/n/abc12345", "_blank", "noopener")
  })

  it("ctrl-click opens in a new tab", async () => {
    await mount()
    $(".card-body").dispatchEvent(new MouseEvent("click", { bubbles: true, ctrlKey: true }))
    expect(assignSpy).not.toHaveBeenCalled()
    expect(openSpy).toHaveBeenCalledWith("/n/abc12345", "_blank", "noopener")
  })

  it("shift-click opens in a new tab/window", async () => {
    await mount()
    $(".card-body").dispatchEvent(new MouseEvent("click", { bubbles: true, shiftKey: true }))
    expect(openSpy).toHaveBeenCalledWith("/n/abc12345", "_blank", "noopener")
  })

  it("middle-click (auxclick, button 1) opens in a new tab", async () => {
    await mount()
    // Real browsers fire `auxclick` for middle button, not `click`.
    $(".card-body").dispatchEvent(new MouseEvent("auxclick", { bubbles: true, button: 1 }))
    expect(assignSpy).not.toHaveBeenCalled()
    expect(openSpy).toHaveBeenCalledWith("/n/abc12345", "_blank", "noopener")
  })

  it("right-click (button 2) does nothing — the browser's context menu owns it", async () => {
    await mount()
    $(".card-body").dispatchEvent(new MouseEvent("auxclick", { bubbles: true, button: 2 }))
    expect(assignSpy).not.toHaveBeenCalled()
    expect(openSpy).not.toHaveBeenCalled()
  })

  it("does NOT navigate when there is a non-empty text selection (drag-to-select)", async () => {
    await mount()
    // Simulate a real text selection in the body.
    const body = $(".card-body")
    const range = document.createRange()
    range.selectNodeContents(body)
    const selection = window.getSelection()
    selection?.removeAllRanges()
    selection?.addRange(range)
    body.click()
    expect(assignSpy).not.toHaveBeenCalled()
    selection?.removeAllRanges()
  })

  it("Enter on the article keyboard-navigates", async () => {
    await mount()
    const article = document.querySelector("article") as HTMLElement
    article.focus()
    article.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Enter" }))
    expect(assignSpy).toHaveBeenCalledWith("/n/abc12345")
  })

  it("Space on the article keyboard-navigates and preventDefaults (no page scroll)", async () => {
    await mount()
    const article = document.querySelector("article") as HTMLElement
    article.focus()
    const ev = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: " " })
    article.dispatchEvent(ev)
    expect(assignSpy).toHaveBeenCalledWith("/n/abc12345")
    expect(ev.defaultPrevented).toBe(true)
  })

  it("Cmd+Enter keyboard opens in a new tab", async () => {
    await mount()
    const article = document.querySelector("article") as HTMLElement
    article.focus()
    article.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Enter", metaKey: true }))
    expect(assignSpy).not.toHaveBeenCalled()
    expect(openSpy).toHaveBeenCalledWith("/n/abc12345", "_blank", "noopener")
  })

  it("Enter while focus is on a child button does NOT card-navigate (the button handles it)", async () => {
    await mount()
    const btn = $(".btn")
    btn.focus()
    btn.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Enter" }))
    expect(assignSpy).not.toHaveBeenCalled()
  })

  it("other keys (Tab, letter keys) do not navigate", async () => {
    await mount()
    const article = document.querySelector("article") as HTMLElement
    article.focus()
    article.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Tab" }))
    article.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "a" }))
    expect(assignSpy).not.toHaveBeenCalled()
  })
})
