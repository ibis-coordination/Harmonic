import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import PulseActionController from "./pulse_action_controller"

describe("PulseActionController", () => {
  let application: Application
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    document.head.innerHTML = `<meta name="csrf-token" content="csrf-test-token">`
    application = Application.start()
    application.register("pulse-action", PulseActionController)
    fetchSpy = vi.spyOn(global, "fetch")
  })

  afterEach(() => {
    application.stop()
    fetchSpy.mockRestore()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  function flushMicrotasks(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0))
  }

  // Mirrors the confirm-read footer rendered by FeedItemComponent: the
  // controller wraps both the button and the "N confirmed" count block.
  async function mountConfirmRead(opts: {
    readCount: number
    withSelfAvatar?: boolean
  }): Promise<HTMLElement> {
    const hidden = opts.readCount === 0 ? "hidden" : ""
    const selfAvatar = opts.withSelfAvatar
      ? `<span class="pulse-confirmed-self" data-pulse-action-target="selfAvatar" hidden>me</span>`
      : ""
    document.body.innerHTML = `
      <div data-controller="pulse-action"
           data-pulse-action-url-value="/n/abc/actions/confirm_read"
           data-pulse-action-loading-text-value="Confirming..."
           data-pulse-action-confirmed-text-value="Confirmed">
        <button type="button" class="pulse-feed-action-btn"
                data-pulse-action-target="button"
                data-action="click->pulse-action#performAction">Confirm read</button>
        <div class="pulse-confirmed-reads" data-pulse-action-target="readCount" ${hidden}>
          <div class="pulse-confirmed-avatars">${selfAvatar}</div>
          <span data-pulse-action-target="count">${opts.readCount} confirmed</span>
        </div>
      </div>
    `
    await new Promise((resolve) => setTimeout(resolve, 0))
    return document.querySelector("[data-controller='pulse-action']") as HTMLElement
  }

  // Mirrors the commitment "Join" footer, which reuses the controller but has
  // no count block and returns a different JSON shape.
  async function mountJoin(): Promise<HTMLButtonElement> {
    document.body.innerHTML = `
      <div data-controller="pulse-action"
           data-pulse-action-url-value="/c/xyz/actions/join_commitment"
           data-pulse-action-loading-text-value="Joining..."
           data-pulse-action-confirmed-text-value="Joined">
        <button type="button" class="pulse-feed-action-btn"
                data-pulse-action-target="button"
                data-action="click->pulse-action#performAction">Join</button>
      </div>
    `
    await new Promise((resolve) => setTimeout(resolve, 0))
    return document.querySelector("button") as HTMLButtonElement
  }

  it("flips the button to the confirmed label on success", async () => {
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ success: true, confirmed_reads: 3 }), { status: 200 })
    )
    const root = await mountConfirmRead({ readCount: 2 })
    const button = root.querySelector("button") as HTMLButtonElement

    button.click()
    await flushMicrotasks()

    expect(button.textContent?.trim()).toBe("Confirmed")
    expect(button.disabled).toBe(true)
  })

  it("updates the confirmed count from the JSON response", async () => {
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ success: true, confirmed_reads: 3 }), { status: 200 })
    )
    const root = await mountConfirmRead({ readCount: 2 })
    const count = root.querySelector("[data-pulse-action-target='count']") as HTMLElement

    root.querySelector("button")!.dispatchEvent(new Event("click"))
    await flushMicrotasks()

    expect(count.textContent?.trim()).toBe("3 confirmed")
  })

  it("reveals the count block and self avatar on the first confirmation", async () => {
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ success: true, confirmed_reads: 1 }), { status: 200 })
    )
    const root = await mountConfirmRead({ readCount: 0, withSelfAvatar: true })
    const readCount = root.querySelector("[data-pulse-action-target='readCount']") as HTMLElement
    const selfAvatar = root.querySelector("[data-pulse-action-target='selfAvatar']") as HTMLElement
    const count = root.querySelector("[data-pulse-action-target='count']") as HTMLElement

    expect(readCount.hidden).toBe(true)
    expect(selfAvatar.hidden).toBe(true)

    root.querySelector("button")!.dispatchEvent(new Event("click"))
    await flushMicrotasks()

    expect(readCount.hidden).toBe(false)
    expect(selfAvatar.hidden).toBe(false)
    expect(count.textContent?.trim()).toBe("1 confirmed")
  })

  it("does not change the count when the request fails", async () => {
    fetchSpy.mockResolvedValue(new Response("", { status: 422 }))
    const root = await mountConfirmRead({ readCount: 2 })
    const count = root.querySelector("[data-pulse-action-target='count']") as HTMLElement
    const button = root.querySelector("button") as HTMLButtonElement

    button.click()
    await flushMicrotasks()

    expect(count.textContent?.trim()).toBe("2 confirmed")
    expect(button.textContent?.trim()).toBe("Confirm read")
    expect(button.disabled).toBe(false)
  })

  it("still works for the commitment join button (no count target)", async () => {
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ success: true }), { status: 200 })
    )
    const button = await mountJoin()

    button.click()
    await flushMicrotasks()

    expect(button.textContent?.trim()).toBe("Joined")
    expect(button.disabled).toBe(true)
  })

  it("tolerates a non-JSON success body without throwing", async () => {
    fetchSpy.mockResolvedValue(new Response("<div>ok</div>", { status: 200 }))
    const root = await mountConfirmRead({ readCount: 2 })
    const count = root.querySelector("[data-pulse-action-target='count']") as HTMLElement

    root.querySelector("button")!.dispatchEvent(new Event("click"))
    await flushMicrotasks()

    // Button still flips; count is left untouched since there was no number.
    expect(root.querySelector("button")!.textContent?.trim()).toBe("Confirmed")
    expect(count.textContent?.trim()).toBe("2 confirmed")
  })
})
