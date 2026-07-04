import { describe, it, expect, beforeEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import FeedBarInputController from "./feed_bar_input_controller"

describe("FeedBarInputController", () => {
  let submitted: boolean

  beforeEach(() => {
    submitted = false
    document.body.innerHTML = `
      <form>
        <textarea name="q" rows="1"
                  data-controller="feed-bar-input"
                  data-action="input->feed-bar-input#resize keydown->feed-bar-input#keydown">cycle:this-week -subtype:comment</textarea>
      </form>
    `
    document.querySelector("form")?.addEventListener("submit", (e) => {
      e.preventDefault()
      submitted = true
    })
    const application = Application.start()
    application.register("feed-bar-input", FeedBarInputController)
  })

  function textarea(): HTMLTextAreaElement {
    return document.querySelector("textarea") as HTMLTextAreaElement
  }

  it("grows to fit its content on input", async () => {
    await vi.waitFor(() => expect(textarea().dataset.controller).toBe("feed-bar-input"))
    Object.defineProperty(textarea(), "scrollHeight", { get: () => 42 })

    textarea().dispatchEvent(new Event("input", { bubbles: true }))

    await vi.waitFor(() => expect(textarea().style.height).toBe("42px"))
  })

  it("submits the form on Enter instead of inserting a newline", async () => {
    await vi.waitFor(() => expect(textarea().dataset.controller).toBe("feed-bar-input"))

    const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
    textarea().dispatchEvent(event)

    await vi.waitFor(() => expect(submitted).toBe(true))
    expect(event.defaultPrevented).toBe(true)
  })

  it("leaves other keys alone", async () => {
    await vi.waitFor(() => expect(textarea().dataset.controller).toBe("feed-bar-input"))

    const event = new KeyboardEvent("keydown", { key: "a", bubbles: true, cancelable: true })
    textarea().dispatchEvent(event)

    expect(submitted).toBe(false)
    expect(event.defaultPrevented).toBe(false)
  })
})
