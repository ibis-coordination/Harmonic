import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import HandleAvailabilityController from "./handle_availability_controller"

describe("HandleAvailabilityController", () => {
  let application: Application
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    application = Application.start()
    application.register("handle-availability", HandleAvailabilityController)
    fetchSpy = vi.spyOn(window, "fetch")
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  async function mount() {
    document.body.innerHTML = `
      <div data-controller="handle-availability"
           data-handle-availability-check-url-value="/collectives/available">
        <span id="example" data-handle-availability-target="example">handle</span>
        <span id="error" data-handle-availability-target="error" style="display:none;">taken</span>
        <input id="input" data-handle-availability-target="input"
               data-action="input->handle-availability#check">
      </div>
    `
    await new Promise((r) => setTimeout(r, 0))
  }

  function input(): HTMLInputElement {
    return document.getElementById("input") as HTMLInputElement
  }
  function example(): HTMLElement {
    return document.getElementById("example") as HTMLElement
  }
  function errorEl(): HTMLElement {
    return document.getElementById("error") as HTMLElement
  }

  function fireInput(value: string) {
    input().value = value
    input().dispatchEvent(new Event("input", { bubbles: true }))
  }

  function mockJson(payload: unknown) {
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify(payload), { headers: { "Content-Type": "application/json" } }),
    )
  }

  it("strips invalid characters from the input rather than fetching", async () => {
    await mount()
    fireInput("Hello World!")
    // Uppercase letters, space, and ! all stripped; lowercase letters kept.
    // No substitution — the regex deletes, doesn't replace.
    expect(input().value).toBe("elloorld")
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("on available handle: clears strikethrough + hides error + removes input-error class", async () => {
    await mount()
    errorEl().style.display = "block"
    input().classList.add("pulse-form-input-error")
    example().style.textDecoration = "line-through"
    mockJson({ available: true })

    fireInput("fresh")
    await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    await new Promise((r) => setTimeout(r, 0))

    expect(example().textContent).toBe("fresh")
    expect(example().style.textDecoration).toBe("none")
    expect(errorEl().style.display).toBe("none")
    expect(input().classList.contains("pulse-form-input-error")).toBe(false)
  })

  it("on taken handle: applies strikethrough + shows error + adds input-error class", async () => {
    await mount()
    mockJson({ available: false })

    fireInput("taken")
    await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    await new Promise((r) => setTimeout(r, 0))

    expect(example().textContent).toBe("taken")
    expect(example().style.textDecoration).toBe("line-through")
    expect(errorEl().style.display).toBe("block")
    expect(input().classList.contains("pulse-form-input-error")).toBe(true)
  })

  it("race guard: a stale fetch response is ignored if the input value has changed", async () => {
    await mount()
    let resolve: (r: Response) => void = () => {}
    fetchSpy.mockReturnValue(new Promise<Response>((r) => { resolve = r }))

    fireInput("first")
    // Don't resolve yet; user types something new.
    input().value = "second"
    // Resolve the stale fetch with available=true; should be ignored.
    resolve(new Response(JSON.stringify({ available: true })))
    await new Promise((r) => setTimeout(r, 0))

    // example was never updated because the response was for "first", not "second"
    expect(example().textContent).toBe("handle")
  })

  it("uses the configured check-url value, passing the handle as a query parameter", async () => {
    await mount()
    mockJson({ available: true })
    fireInput("xyz")
    await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    expect(fetchSpy.mock.calls[0][0]).toBe("/collectives/available?handle=xyz")
  })
})
