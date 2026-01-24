import { describe, it, expect, beforeEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import FormTrackerController from "./form_tracker_controller"

describe("FormTrackerController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("form-tracker", FormTrackerController)
  })

  describe("with text input", () => {
    beforeEach(() => {
      document.body.innerHTML = `
        <form data-controller="form-tracker">
          <input type="text" name="name" value="Original" data-action="input->form-tracker#trackChange" />
          <button type="submit" data-form-tracker-target="submit">Save</button>
        </form>
      `
    })

    it("starts with submit button disabled when no changes", () => {
      const button = document.querySelector("button") as HTMLButtonElement
      expect(button.disabled).toBe(true)
      expect(button.classList.contains("pulse-action-btn-disabled")).toBe(true)
    })

    it("enables submit button when value changes", () => {
      const input = document.querySelector("input") as HTMLInputElement
      const button = document.querySelector("button") as HTMLButtonElement

      input.value = "Changed"
      input.dispatchEvent(new Event("input", { bubbles: true }))

      expect(button.disabled).toBe(false)
      expect(button.classList.contains("pulse-action-btn-disabled")).toBe(false)
    })

    it("disables submit button when value returns to original", () => {
      const input = document.querySelector("input") as HTMLInputElement
      const button = document.querySelector("button") as HTMLButtonElement

      // Change value
      input.value = "Changed"
      input.dispatchEvent(new Event("input", { bubbles: true }))
      expect(button.disabled).toBe(false)

      // Change back to original
      input.value = "Original"
      input.dispatchEvent(new Event("input", { bubbles: true }))
      expect(button.disabled).toBe(true)
    })
  })

  describe("with Rails checkbox pattern (hidden field + checkbox)", () => {
    beforeEach(() => {
      // Rails generates hidden field with value="0" followed by checkbox with value="1"
      // When checkbox is checked, FormData contains both, but checkbox value comes last
      document.body.innerHTML = `
        <form data-controller="form-tracker">
          <input type="hidden" name="feature_enabled" value="0" />
          <input type="checkbox" name="feature_enabled" value="1" checked data-action="change->form-tracker#trackChange" />
          <button type="submit" data-form-tracker-target="submit">Save</button>
        </form>
      `
    })

    it("starts with submit button disabled when checkbox is unchanged", () => {
      const button = document.querySelector("button") as HTMLButtonElement
      // The checkbox is checked initially, so initial state captures "1"
      // No changes have been made, so button should be disabled
      expect(button.disabled).toBe(true)
    })

    it("enables submit button when checkbox is unchecked", () => {
      const checkbox = document.querySelector(
        'input[type="checkbox"]',
      ) as HTMLInputElement
      const button = document.querySelector("button") as HTMLButtonElement

      // Uncheck the checkbox - now only hidden field "0" will be in FormData
      checkbox.checked = false
      checkbox.dispatchEvent(new Event("change", { bubbles: true }))

      expect(button.disabled).toBe(false)
    })

    it("disables submit button when checkbox returns to original state", () => {
      const checkbox = document.querySelector(
        'input[type="checkbox"]',
      ) as HTMLInputElement
      const button = document.querySelector("button") as HTMLButtonElement

      // Uncheck
      checkbox.checked = false
      checkbox.dispatchEvent(new Event("change", { bubbles: true }))
      expect(button.disabled).toBe(false)

      // Check again (back to original)
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change", { bubbles: true }))
      expect(button.disabled).toBe(true)
    })
  })

  describe("with initially unchecked checkbox", () => {
    beforeEach(() => {
      document.body.innerHTML = `
        <form data-controller="form-tracker">
          <input type="hidden" name="feature_enabled" value="0" />
          <input type="checkbox" name="feature_enabled" value="1" data-action="change->form-tracker#trackChange" />
          <button type="submit" data-form-tracker-target="submit">Save</button>
        </form>
      `
    })

    it("starts disabled when checkbox is unchecked", () => {
      const button = document.querySelector("button") as HTMLButtonElement
      expect(button.disabled).toBe(true)
    })

    it("enables when checkbox is checked", () => {
      const checkbox = document.querySelector(
        'input[type="checkbox"]',
      ) as HTMLInputElement
      const button = document.querySelector("button") as HTMLButtonElement

      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change", { bubbles: true }))

      expect(button.disabled).toBe(false)
    })
  })

  describe("with select element", () => {
    beforeEach(() => {
      document.body.innerHTML = `
        <form data-controller="form-tracker">
          <select name="timezone" data-action="change->form-tracker#trackChange">
            <option value="UTC" selected>UTC</option>
            <option value="America/New_York">New York</option>
          </select>
          <button type="submit" data-form-tracker-target="submit">Save</button>
        </form>
      `
    })

    it("enables submit when select value changes", () => {
      const select = document.querySelector("select") as HTMLSelectElement
      const button = document.querySelector("button") as HTMLButtonElement

      select.value = "America/New_York"
      select.dispatchEvent(new Event("change", { bubbles: true }))

      expect(button.disabled).toBe(false)
    })
  })
})
