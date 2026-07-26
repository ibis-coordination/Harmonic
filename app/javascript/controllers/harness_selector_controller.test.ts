import { describe, it, expect, beforeEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import HarnessSelectorController from "./harness_selector_controller"

const BASE = "npx @ibis-coordination/harmonic-bridge setup-sprite --from https://x.example/b/1 --sprite-name harmonic-alice"

describe("HarnessSelectorController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("harness-selector", HarnessSelectorController)

    document.body.innerHTML = `
      <div data-controller="harness-selector">
        <label><input type="radio" name="sprite_harness" value="" checked
                      data-action="change->harness-selector#select"></label>
        <label><input type="radio" name="sprite_harness" value="claude-code"
                      data-action="change->harness-selector#select"></label>
        <label><input type="radio" name="sprite_harness" value="goose"
                      data-action="change->harness-selector#select"></label>
        <pre data-harness-selector-target="command">${BASE}</pre>
        <span data-controller="clipboard">
          <input type="text" value="${BASE}" data-clipboard-target="source" />
        </span>
      </div>
    `
  })

  function pick(value: string): void {
    const radio = document.querySelector(`input[value="${value}"]`) as HTMLInputElement
    radio.checked = true
    radio.dispatchEvent(new Event("change", { bubbles: true }))
  }

  function shown(): string {
    return (document.querySelector("[data-harness-selector-target='command']") as HTMLElement).textContent!
  }

  function copied(): string {
    return (document.querySelector("[data-clipboard-target='source']") as HTMLInputElement).value
  }

  it("appends the chosen harness to the command", () => {
    pick("goose")
    expect(shown()).toBe(`${BASE} --harness goose`)
  })

  it("keeps the copy button's payload in step with what is displayed", () => {
    // The displayed command is not what gets pasted — the copy button reads
    // its own hidden input, so a stale one hands over the wrong command.
    pick("claude-code")
    expect(copied()).toBe(`${BASE} --harness claude-code`)
  })

  it("switching harnesses replaces rather than accumulates flags", () => {
    pick("claude-code")
    pick("goose")
    expect(shown()).toBe(`${BASE} --harness goose`)
  })

  it("choosing none returns the harness-neutral command", () => {
    pick("goose")
    pick("")
    expect(shown()).toBe(BASE)
    expect(copied()).toBe(BASE)
  })
})
