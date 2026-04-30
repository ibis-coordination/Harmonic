import { describe, it, expect, beforeEach, vi, type Mock } from "vitest"
import { Application } from "@hotwired/stimulus"
import DecisionController from "./decision_controller"
import { waitForController } from "../test/setup"

const flushPromises = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0))
  await new Promise((resolve) => setTimeout(resolve, 0))
}

function buildOptionItem(id: string, title: string, accepted: boolean, preferred: boolean): string {
  return `
    <li class="pulse-option-item" data-option-id="${id}">
      <input type="checkbox" class="pulse-acceptance-checkbox" id="option${id}" ${accepted ? "checked" : ""} />
      <input type="checkbox" class="pulse-star-checkbox" id="star-option${id}" ${preferred ? "checked" : ""} />
      <label for="option${id}" class="pulse-option-label">${title}</label>
    </li>
  `
}

function buildDecisionHTML(options: { id: string; title: string; accepted: boolean; preferred: boolean }[]): string {
  const optionItems = options.map((o) => buildOptionItem(o.id, o.title, o.accepted, o.preferred)).join("")
  return `
    <span data-controller="decision">
      <span data-decision-target="optionsSection" data-url="/options.html" data-deadline="${new Date(Date.now() + 86400000).toISOString()}">
        <form data-decision-target="voteForm">
          <ul class="pulse-options-list">
            <span data-decision-target="list">
              ${optionItems}
            </span>
          </ul>
          <button type="submit" class="pulse-action-btn" data-decision-target="submitButton" disabled>
            Submit Vote
          </button>
        </form>
        <input type="text" data-decision-target="input" data-decision-id="dec-1" />
      </span>
    </span>
  `
}

describe("DecisionController", () => {
  let application: Application
  let mockFetch: Mock<typeof fetch>

  beforeEach(() => {
    mockFetch = vi.fn<typeof fetch>().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve(""),
    } as unknown as Response)
    global.fetch = mockFetch

    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    application = Application.start()
    application.register("decision", DecisionController)
  })

  describe("submit button state", () => {
    it("starts disabled when no changes have been made", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
        { id: "2", title: "Option B", accepted: false, preferred: false },
      ])
      await waitForController()

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      expect(button.disabled).toBe(true)
    })

    it("starts disabled when user has existing votes", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: true, preferred: false },
        { id: "2", title: "Option B", accepted: true, preferred: true },
      ])
      await waitForController()

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      expect(button.disabled).toBe(true)
    })

    it("becomes enabled when a checkbox is changed", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
        { id: "2", title: "Option B", accepted: false, preferred: false },
      ])
      await waitForController()

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      const checkbox = document.querySelector("#option1") as HTMLInputElement

      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change"))

      expect(button.disabled).toBe(false)
    })

    it("becomes disabled again when checkbox is reverted to original state", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
      ])
      await waitForController()

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      const checkbox = document.querySelector("#option1") as HTMLInputElement

      // Check it
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change"))
      expect(button.disabled).toBe(false)

      // Uncheck it back
      checkbox.checked = false
      checkbox.dispatchEvent(new Event("change"))
      expect(button.disabled).toBe(true)
    })

    it("becomes enabled when star checkbox is changed", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: true, preferred: false },
      ])
      await waitForController()

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      const star = document.querySelector("#star-option1") as HTMLInputElement

      star.checked = true
      star.dispatchEvent(new Event("change"))

      expect(button.disabled).toBe(false)
    })
  })

  describe("adding options", () => {
    it("appends new option without replacing existing ones", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
      ])
      await waitForController()

      const newOptionHtml =
        buildOptionItem("1", "Option A", false, false) +
        buildOptionItem("2", "Option B", false, false)

      // First call is createOption (POST), mock it
      mockFetch.mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve(newOptionHtml),
      } as unknown as Response)

      const input = document.querySelector("[data-decision-target='input']") as HTMLInputElement
      input.value = "Option B"

      // Simulate Stimulus action by getting the controller and calling add directly
      const controllerElement = document.querySelector("[data-controller='decision']") as HTMLElement
      const controller = application.getControllerForElementAndIdentifier(controllerElement, "decision") as DecisionController
      const event = new Event("submit", { cancelable: true })
      controller.add(event)

      await flushPromises()
      await flushPromises()

      const items = document.querySelectorAll("li[data-option-id]")
      expect(items.length).toBe(2)
    })

    it("preserves local checkbox state when adding option", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
      ])
      await waitForController()

      // User checks Option A locally
      const checkbox = document.querySelector("#option1") as HTMLInputElement
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change"))

      const button = document.querySelector("[data-decision-target='submitButton']") as HTMLButtonElement
      expect(button.disabled).toBe(false)

      // Server returns both options (Option A unchecked from server POV)
      const newOptionHtml =
        buildOptionItem("1", "Option A", false, false) +
        buildOptionItem("2", "Option B", false, false)

      mockFetch.mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve(newOptionHtml),
      } as unknown as Response)

      const input = document.querySelector("[data-decision-target='input']") as HTMLInputElement
      input.value = "Option B"

      const controllerElement = document.querySelector("[data-controller='decision']") as HTMLElement
      const controller = application.getControllerForElementAndIdentifier(controllerElement, "decision") as DecisionController
      const event = new Event("submit", { cancelable: true })
      controller.add(event)

      await flushPromises()
      await flushPromises()

      // Option A should still be checked (local state preserved)
      expect(checkbox.checked).toBe(true)
      // Submit button should still be enabled
      expect(button.disabled).toBe(false)
    })
  })

  describe("poll refresh", () => {
    it("does not overwrite local checkbox changes", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
      ])
      await waitForController()

      // User checks Option A locally
      const checkbox = document.querySelector("#option1") as HTMLInputElement
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change"))

      // Server returns Option A as unchecked (saved state)
      const serverHtml = buildOptionItem("1", "Option A", false, false)
      mockFetch.mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve(serverHtml),
      } as unknown as Response)

      // Call refreshOptions directly
      const controllerElement = document.querySelector("[data-controller='decision']") as HTMLElement
      const controller = application.getControllerForElementAndIdentifier(controllerElement, "decision") as DecisionController
      const pollEvent = new Event("poll", { cancelable: true })
      await controller.refreshOptions(pollEvent)

      await flushPromises()
      await flushPromises()

      // Local state should be preserved
      expect(checkbox.checked).toBe(true)
    })

    it("adds new options from other users without affecting existing state", async () => {
      document.body.innerHTML = buildDecisionHTML([
        { id: "1", title: "Option A", accepted: false, preferred: false },
      ])
      await waitForController()

      // User checks Option A
      const checkbox = document.querySelector("#option1") as HTMLInputElement
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change"))

      // Server returns original + new option from another user
      const serverHtml =
        buildOptionItem("1", "Option A", false, false) +
        buildOptionItem("2", "Option B", false, false)

      mockFetch.mockResolvedValueOnce({
        ok: true,
        text: () => Promise.resolve(serverHtml),
      } as unknown as Response)

      // Call refreshOptions directly to avoid event binding timing issues
      const controllerElement = document.querySelector("[data-controller='decision']") as HTMLElement
      const controller = application.getControllerForElementAndIdentifier(controllerElement, "decision") as DecisionController
      const pollEvent = new Event("poll", { cancelable: true })
      await controller.refreshOptions(pollEvent)

      await flushPromises()
      await flushPromises()

      // Should now have 2 options
      const items = document.querySelectorAll("li[data-option-id]")
      expect(items.length).toBe(2)

      // Option A should still be checked
      expect(checkbox.checked).toBe(true)
    })
  })
})
