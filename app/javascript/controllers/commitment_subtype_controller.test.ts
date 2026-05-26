import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import CommitmentSubtypeController from "./commitment_subtype_controller"
import { waitForController } from "../test/setup"

describe("CommitmentSubtypeController", () => {
  let application: Application

  beforeEach(() => {
    document.body.innerHTML = ""
    application = Application.start()
    application.register("commitment-subtype", CommitmentSubtypeController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  function renderForm() {
    document.body.innerHTML = `
      <form data-controller="commitment-subtype">
        <input type="hidden" name="subtype" value="action" data-commitment-subtype-target="subtypeInput">
        <button type="button" data-action="commitment-subtype#selectAction" data-commitment-subtype-target="actionBtn" class="pulse-action-btn">Action</button>
        <button type="button" data-action="commitment-subtype#selectCalendarEvent" data-commitment-subtype-target="calendarEventBtn" class="pulse-action-btn-secondary">Event</button>
        <button type="button" data-action="commitment-subtype#selectPolicy" data-commitment-subtype-target="policyBtn" class="pulse-action-btn-secondary">Policy</button>
        <div data-commitment-subtype-target="calendarEventFields" style="display: none;">Calendar fields</div>
        <h2 data-commitment-subtype-target="criticalMassTitle">Critical Mass</h2>
        <p data-commitment-subtype-target="criticalMassDescription">Desc</p>
        <span data-commitment-subtype-target="criticalMassSuffix">participant(s) required</span>
        <h2 data-commitment-subtype-target="deadlineTitle">Deadline</h2>
        <p data-commitment-subtype-target="deadlineDescription">When?</p>
        <input type="submit" data-commitment-subtype-target="submitButton" value="Start Commitment">
      </form>
    `
  }

  it("starts in action mode by default with calendar fields hidden", async () => {
    renderForm()
    await waitForController()

    const calendarFields = document.querySelector("[data-commitment-subtype-target='calendarEventFields']") as HTMLElement
    expect(calendarFields.style.display).toBe("none")
  })

  it("switches to calendar event mode", async () => {
    renderForm()
    await waitForController()

    const btn = document.querySelector("[data-commitment-subtype-target='calendarEventBtn']") as HTMLButtonElement
    btn.click()

    const input = document.querySelector("[data-commitment-subtype-target='subtypeInput']") as HTMLInputElement
    const calendarFields = document.querySelector("[data-commitment-subtype-target='calendarEventFields']") as HTMLElement
    const criticalMassTitle = document.querySelector("[data-commitment-subtype-target='criticalMassTitle']") as HTMLElement
    const deadlineTitle = document.querySelector("[data-commitment-subtype-target='deadlineTitle']") as HTMLElement

    expect(input.value).toBe("calendar_event")
    expect(calendarFields.style.display).toBe("")
    expect(criticalMassTitle.textContent).toBe("Minimum attendees")
    expect(deadlineTitle.textContent).toBe("RSVP by")
  })

  it("switches to policy mode without hiding any sections (relabels only)", async () => {
    renderForm()
    await waitForController()

    const btn = document.querySelector("[data-commitment-subtype-target='policyBtn']") as HTMLButtonElement
    btn.click()

    const input = document.querySelector("[data-commitment-subtype-target='subtypeInput']") as HTMLInputElement
    const calendarFields = document.querySelector("[data-commitment-subtype-target='calendarEventFields']") as HTMLElement
    const criticalMassTitle = document.querySelector("[data-commitment-subtype-target='criticalMassTitle']") as HTMLElement
    const criticalMassSuffix = document.querySelector("[data-commitment-subtype-target='criticalMassSuffix']") as HTMLElement
    const deadlineTitle = document.querySelector("[data-commitment-subtype-target='deadlineTitle']") as HTMLElement

    expect(input.value).toBe("policy")
    expect(calendarFields.style.display).toBe("none")
    expect(criticalMassTitle.textContent).toBe("Critical Mass")
    expect(criticalMassSuffix.textContent).toBe("signatories required")
    expect(deadlineTitle.textContent).toBe("Deadline")
  })

  it("switches back to action mode after switching to policy", async () => {
    renderForm()
    await waitForController()

    const policyBtn = document.querySelector("[data-commitment-subtype-target='policyBtn']") as HTMLButtonElement
    policyBtn.click()

    const actionBtn = document.querySelector("[data-commitment-subtype-target='actionBtn']") as HTMLButtonElement
    actionBtn.click()

    const input = document.querySelector("[data-commitment-subtype-target='subtypeInput']") as HTMLInputElement
    const criticalMassTitle = document.querySelector("[data-commitment-subtype-target='criticalMassTitle']") as HTMLElement
    const criticalMassSuffix = document.querySelector("[data-commitment-subtype-target='criticalMassSuffix']") as HTMLElement

    expect(input.value).toBe("action")
    expect(criticalMassTitle.textContent).toBe("Critical Mass")
    expect(criticalMassSuffix.textContent).toBe("participant(s) required")
  })

  it("updates submit button label per subtype", async () => {
    renderForm()
    await waitForController()

    const submit = document.querySelector("[data-commitment-subtype-target='submitButton']") as HTMLInputElement
    ;(document.querySelector("[data-commitment-subtype-target='policyBtn']") as HTMLButtonElement).click()
    expect(submit.value).toBe("Publish Policy")
    ;(document.querySelector("[data-commitment-subtype-target='calendarEventBtn']") as HTMLButtonElement).click()
    expect(submit.value).toBe("Create Event")
    ;(document.querySelector("[data-commitment-subtype-target='actionBtn']") as HTMLButtonElement).click()
    expect(submit.value).toBe("Start Commitment")
  })
})
