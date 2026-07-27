import { describe, it, expect, beforeEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import HarnessSelectorController from "./harness_selector_controller"

const BASE = "npx @ibis-coordination/harmonic-bridge setup-sprite --from https://x.example/b/1 --sprite-name harmonic-alice"
const MODELS = ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-5"]

describe("HarnessSelectorController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("harness-selector", HarnessSelectorController)
  })

  // Mirrors show.html.erb: the base command arrives as a Stimulus value, and
  // the <pre> may disagree with it (Turbo restores the mutated DOM). The
  // model radios exist only when the setup carries the LLM opt-in.
  function render(preContent: string, opts?: { models?: readonly string[]; checkedModel?: string }): void {
    const modelRadios = (opts?.models ?? [])
      .map(
        (m) => `
        <label><input type="radio" name="sprite_model" value="${m}"
                      ${m === (opts?.checkedModel ?? opts?.models?.[0]) ? "checked" : ""}
                      data-action="change->harness-selector#selectModel"></label>`,
      )
      .join("")
    document.body.innerHTML = `
      <div data-controller="harness-selector" data-harness-selector-base-value="${BASE}">
        <label><input type="radio" name="sprite_harness" value="" checked
                      data-action="change->harness-selector#selectHarness"></label>
        <label><input type="radio" name="sprite_harness" value="claude-code"
                      data-action="change->harness-selector#selectHarness"></label>
        <label><input type="radio" name="sprite_harness" value="goose"
                      data-action="change->harness-selector#selectHarness"></label>
        ${modelRadios}
        <pre data-harness-selector-target="command">${preContent}</pre>
        <span data-controller="clipboard">
          <input type="text" value="${BASE}" data-clipboard-target="source" />
        </span>
      </div>
    `
  }

  // Stimulus connects re-rendered elements via MutationObserver — let that
  // microtask flush before dispatching events or reading connect()'s output.
  async function connected(): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

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

  it("appends the chosen harness to the command", async () => {
    render(BASE)
    await connected()
    pick("goose")
    expect(shown()).toBe(`${BASE} --harness goose`)
  })

  it("keeps the copy button's payload in step with what is displayed", async () => {
    // The displayed command is not what gets pasted — the copy button reads
    // its own hidden input, so a stale one hands over the wrong command.
    render(BASE)
    await connected()
    pick("claude-code")
    expect(copied()).toBe(`${BASE} --harness claude-code`)
  })

  it("switching harnesses replaces rather than accumulates flags", async () => {
    render(BASE)
    await connected()
    pick("claude-code")
    pick("goose")
    expect(shown()).toBe(`${BASE} --harness goose`)
  })

  it("choosing none returns the harness-neutral command", async () => {
    render(BASE)
    await connected()
    pick("goose")
    pick("")
    expect(shown()).toBe(BASE)
    expect(copied()).toBe(BASE)
  })

  it("renders the pre-checked model into the command on connect", async () => {
    // The server renders the base command without flags; the first model is
    // pre-checked, so the visible command must pick it up immediately.
    render(BASE, { models: MODELS })
    await connected()
    expect(shown()).toBe(`${BASE} --model ${MODELS[0]}`)
    expect(copied()).toBe(`${BASE} --model ${MODELS[0]}`)
  })

  it("composes harness and model flags", async () => {
    render(BASE, { models: MODELS })
    await connected()
    pick("goose")
    pick(MODELS[1]!)
    expect(shown()).toBe(`${BASE} --harness goose --model ${MODELS[1]}`)
    expect(copied()).toBe(`${BASE} --harness goose --model ${MODELS[1]}`)
  })

  it("switching models replaces rather than accumulates", async () => {
    render(BASE, { models: MODELS })
    await connected()
    pick(MODELS[1]!)
    pick(MODELS[0]!)
    expect(shown()).toBe(`${BASE} --model ${MODELS[0]}`)
  })

  it("survives a Turbo cache restore of the mutated DOM", async () => {
    // Turbo snapshots the page after mutation: the <pre> already carries
    // flags and the radios keep their checked state when connect() runs
    // again. The command must be recomputed from the base value + checked
    // radios, not derived from the mutated <pre>.
    render(`${BASE} --harness goose --model ${MODELS[1]}`, { models: MODELS, checkedModel: MODELS[1] })
    await connected()
    expect(shown()).toBe(`${BASE} --model ${MODELS[1]}`)
    pick("claude-code")
    expect(shown()).toBe(`${BASE} --harness claude-code --model ${MODELS[1]}`)
    expect(copied()).toBe(`${BASE} --harness claude-code --model ${MODELS[1]}`)
  })
})
