import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import CountdownController from "./countdown_controller"

describe("CountdownController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()
    application = Application.start()
    application.register("countdown", CountdownController)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("displays countdown in hours:minutes:seconds format", async () => {
    // Set "now" to a fixed time
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    // End time is 2 hours, 30 minutes, 45 seconds in the future
    const endTime = new Date("2024-01-01T14:30:45Z").toISOString()

    document.body.innerHTML = `
      <div data-controller="countdown"
           data-countdown-end-time-value="${endTime}"
           data-countdown-base-unit-value="seconds">
        <span data-countdown-target="time"></span>
      </div>
    `

    // Flush microtasks to allow controller to connect (without running interval)
    await vi.advanceTimersByTimeAsync(0)

    const timeElement = document.querySelector("[data-countdown-target='time']")
    expect(timeElement?.innerHTML).toBe("2h : 30m : 45s")
  })

  it("displays countdown with days when appropriate", async () => {
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"))

    // 3 days, 5 hours from now
    const endTime = new Date("2024-01-04T05:00:00Z").toISOString()

    document.body.innerHTML = `
      <div data-controller="countdown"
           data-countdown-end-time-value="${endTime}"
           data-countdown-base-unit-value="seconds">
        <span data-countdown-target="time"></span>
      </div>
    `

    await vi.advanceTimersByTimeAsync(0)

    const timeElement = document.querySelector("[data-countdown-target='time']")
    expect(timeElement?.innerHTML).toBe("3d : 5h : 0m : 00s")
  })

  it("shows 0 when countdown has expired", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    // End time is in the past
    const endTime = new Date("2024-01-01T11:00:00Z").toISOString()

    document.body.innerHTML = `
      <div data-controller="countdown"
           data-countdown-end-time-value="${endTime}"
           data-countdown-base-unit-value="seconds">
        <span data-countdown-target="time"></span>
      </div>
    `

    await vi.advanceTimersByTimeAsync(0)

    const timeElement = document.querySelector("[data-countdown-target='time']") as HTMLElement
    expect(timeElement?.innerText).toBe("0")
  })

  it("updates countdown every second", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    const endTime = new Date("2024-01-01T12:00:10Z").toISOString()

    document.body.innerHTML = `
      <div data-controller="countdown"
           data-countdown-end-time-value="${endTime}"
           data-countdown-base-unit-value="seconds">
        <span data-countdown-target="time"></span>
      </div>
    `

    // Flush microtasks to connect controller
    await vi.advanceTimersByTimeAsync(0)

    const timeElement = document.querySelector("[data-countdown-target='time']")
    expect(timeElement?.innerHTML).toBe("10s")

    // Advance timers by 1 second - this runs the interval callback
    vi.advanceTimersByTime(1000)
    expect(timeElement?.innerHTML).toBe("09s")

    // Advance by another 4 seconds
    vi.advanceTimersByTime(4000)
    expect(timeElement?.innerHTML).toBe("05s")
  })
})
