import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import DatetimeInputController from "./datetime_input_controller"
import { waitForController } from "../test/setup"

describe("DatetimeInputController", () => {
  let application: Application

  beforeEach(() => {
    document.body.innerHTML = ""
    application = Application.start()
    application.register("datetime-input", DatetimeInputController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  function renderInput(options: {
    defaultOffset?: string
    requireFuture?: string
    value?: string
    timezoneOptions?: string[]
  } = {}) {
    const offset = options.defaultOffset ?? "7d"
    const requireFuture = options.requireFuture ?? "true"
    const value = options.value ? `value="${options.value}"` : ""
    const tzOptions = (options.timezoneOptions ?? ["UTC", "Eastern Time (US & Canada)", "Pacific Time (US & Canada)"])
      .map((tz) => `<option value="${tz}">${tz}</option>`)
      .join("")

    document.body.innerHTML = `
      <div data-controller="datetime-input"
           data-datetime-input-default-offset-value="${offset}"
           data-datetime-input-require-future-value="${requireFuture}">
        <input type="datetime-local"
               name="scheduled_for"
               ${value}
               data-datetime-input-target="datetimeInput"
               data-action="change->datetime-input#validate">
        <select name="timezone"
                data-datetime-input-target="timezoneSelect"
                data-action="change->datetime-input#validate">
          ${tzOptions}
        </select>
        <span data-datetime-input-target="error" style="display: none;"></span>
        <span data-datetime-input-target="countdown"></span>
      </div>
    `
  }

  // --- Timezone autodetection ---

  it("autodetects browser timezone and sets the select value", async () => {
    vi.spyOn(Intl, "DateTimeFormat").mockImplementation(
      () => ({ resolvedOptions: () => ({ timeZone: "America/New_York" }) }) as Intl.DateTimeFormat
    )

    renderInput()
    await waitForController()

    const select = document.querySelector("[data-datetime-input-target='timezoneSelect']") as HTMLSelectElement
    expect(select.value).toBe("Eastern Time (US & Canada)")
  })

  it("leaves select unchanged for unknown IANA timezone", async () => {
    vi.spyOn(Intl, "DateTimeFormat").mockImplementation(
      () => ({ resolvedOptions: () => ({ timeZone: "Mars/Olympus_Mons" }) }) as Intl.DateTimeFormat
    )

    renderInput()
    await waitForController()

    const select = document.querySelector("[data-datetime-input-target='timezoneSelect']") as HTMLSelectElement
    expect(select.value).toBe("UTC") // first option, server default
  })

  // --- Default offset ---

  it("prefills datetime input with default offset when empty", async () => {
    renderInput({ defaultOffset: "7d" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    expect(input.value).not.toBe("")

    // Should be approximately 7 days from now
    const prefilled = new Date(input.value)
    const expected = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
    expect(Math.abs(prefilled.getTime() - expected.getTime())).toBeLessThan(60_000) // within 1 minute
  })

  it("does not overwrite existing value", async () => {
    renderInput({ defaultOffset: "7d", value: "2030-01-15T10:00" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    expect(input.value).toBe("2030-01-15T10:00")
  })

  it("does not prefill when defaultOffset is empty", async () => {
    renderInput({ defaultOffset: "" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    expect(input.value).toBe("")
  })

  // --- Future validation ---

  it("shows error for past datetime", async () => {
    renderInput({ requireFuture: "true", value: "2020-01-01T00:00" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    input.dispatchEvent(new Event("change"))

    const error = document.querySelector("[data-datetime-input-target='error']") as HTMLElement
    expect(error.style.display).not.toBe("none")
    expect(error.textContent).toContain("future")
  })

  it("clears error for future datetime", async () => {
    renderInput({ requireFuture: "true" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    // Set a future time
    const future = new Date(Date.now() + 86_400_000)
    input.value = future.toISOString().slice(0, 16)
    input.dispatchEvent(new Event("change"))

    const error = document.querySelector("[data-datetime-input-target='error']") as HTMLElement
    expect(error.style.display).toBe("none")
  })

  it("does not validate when requireFuture is false", async () => {
    renderInput({ requireFuture: "false", value: "2020-01-01T00:00" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    input.dispatchEvent(new Event("change"))

    const error = document.querySelector("[data-datetime-input-target='error']") as HTMLElement
    expect(error.style.display).toBe("none")
  })

  // --- Min attribute ---

  it("sets min attribute to current time on connect", async () => {
    renderInput()
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    expect(input.min).not.toBe("")

    const minDate = new Date(input.min)
    expect(Math.abs(minDate.getTime() - Date.now())).toBeLessThan(60_000)
  })

  // --- Countdown preview ---

  it("updates countdown end-time attribute for future datetime", async () => {
    const future = new Date(Date.now() + 3 * 86_400_000)
    renderInput({ value: future.toISOString().slice(0, 16) })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    input.dispatchEvent(new Event("change"))

    const countdownEl = document.querySelector("[data-datetime-input-target='countdown']") as HTMLElement
    expect(countdownEl.style.display).not.toBe("none")
    // Countdown receives a full ISO 8601 UTC string (timezone-aware)
    const endTime = countdownEl.getAttribute("data-countdown-end-time-value")!
    const parsedEnd = new Date(endTime)
    // Should be within 1 minute of the intended future date (rounding from datetime-local truncation)
    expect(Math.abs(parsedEnd.getTime() - future.getTime())).toBeLessThan(60_000)
  })

  it("hides countdown for past datetime", async () => {
    renderInput({ value: "2020-01-01T00:00", requireFuture: "true" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    input.dispatchEvent(new Event("change"))

    const countdownEl = document.querySelector("[data-datetime-input-target='countdown']") as HTMLElement
    expect(countdownEl.style.display).toBe("none")
  })

  it("hides countdown when input is empty", async () => {
    renderInput()
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    input.value = ""
    input.dispatchEvent(new Event("change"))

    const countdownEl = document.querySelector("[data-datetime-input-target='countdown']") as HTMLElement
    expect(countdownEl.style.display).toBe("none")
  })

  it("shows countdown on connect when default value is prefilled", async () => {
    renderInput({ defaultOffset: "7d" })
    await waitForController()

    const countdownEl = document.querySelector("[data-datetime-input-target='countdown']") as HTMLElement
    expect(countdownEl.style.display).not.toBe("none")
    expect(countdownEl.getAttribute("data-countdown-end-time-value")).not.toBe("")
  })

  // --- Offset parsing ---

  it("supports hours offset", async () => {
    renderInput({ defaultOffset: "2h" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    const prefilled = new Date(input.value)
    const expected = new Date(Date.now() + 2 * 60 * 60 * 1000)
    expect(Math.abs(prefilled.getTime() - expected.getTime())).toBeLessThan(60_000)
  })

  it("supports weeks offset", async () => {
    renderInput({ defaultOffset: "1w" })
    await waitForController()

    const input = document.querySelector("[data-datetime-input-target='datetimeInput']") as HTMLInputElement
    const prefilled = new Date(input.value)
    const expected = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
    expect(Math.abs(prefilled.getTime() - expected.getTime())).toBeLessThan(60_000)
  })
})
