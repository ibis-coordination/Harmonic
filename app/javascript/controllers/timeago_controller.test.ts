import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import TimeagoController from "./timeago_controller"

describe("TimeagoController", () => {
  let application: Application

  beforeEach(() => {
    vi.useFakeTimers()
    application = Application.start()
    application.register("timeago", TimeagoController)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("displays relative time for a past date", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    // 5 minutes ago
    const datetime = new Date("2024-01-01T11:55:00Z").toISOString()

    document.body.innerHTML = `
      <span data-controller="timeago"
            data-timeago-datetime-value="${datetime}">...</span>
    `

    // Flush microtasks to connect controller without running interval
    await vi.advanceTimersByTimeAsync(0)

    const element = document.querySelector("[data-controller='timeago']")
    expect(element?.innerHTML).toBe("5 minutes ago")
  })

  it("displays relative time for hours ago", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    // 3 hours ago
    const datetime = new Date("2024-01-01T09:00:00Z").toISOString()

    document.body.innerHTML = `
      <span data-controller="timeago"
            data-timeago-datetime-value="${datetime}">...</span>
    `

    await vi.advanceTimersByTimeAsync(0)

    const element = document.querySelector("[data-controller='timeago']")
    expect(element?.innerHTML).toBe("about 3 hours ago")
  })

  it("displays relative time for days ago", async () => {
    vi.setSystemTime(new Date("2024-01-05T12:00:00Z"))

    // 4 days ago
    const datetime = new Date("2024-01-01T12:00:00Z").toISOString()

    document.body.innerHTML = `
      <span data-controller="timeago"
            data-timeago-datetime-value="${datetime}">...</span>
    `

    await vi.advanceTimersByTimeAsync(0)

    const element = document.querySelector("[data-controller='timeago']")
    expect(element?.innerHTML).toBe("4 days ago")
  })

  it("only updates if initial content is '...'", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    const datetime = new Date("2024-01-01T11:55:00Z").toISOString()

    document.body.innerHTML = `
      <span data-controller="timeago"
            data-timeago-datetime-value="${datetime}">Already set</span>
    `

    await vi.advanceTimersByTimeAsync(0)

    const element = document.querySelector("[data-controller='timeago']")
    // Should not have been updated because initial content wasn't "..."
    expect(element?.innerHTML).toBe("Already set")
  })

  it("refreshes the time periodically", async () => {
    vi.setSystemTime(new Date("2024-01-01T12:00:00Z"))

    const datetime = new Date("2024-01-01T11:59:00Z").toISOString()

    document.body.innerHTML = `
      <span data-controller="timeago"
            data-timeago-datetime-value="${datetime}">...</span>
    `

    await vi.advanceTimersByTimeAsync(0)

    const element = document.querySelector("[data-controller='timeago']")
    expect(element?.innerHTML).toBe("1 minute ago")

    // Advance by 60 seconds - this runs the interval and advances system time
    vi.advanceTimersByTime(60000)
    expect(element?.innerHTML).toBe("2 minutes ago")
  })
})
