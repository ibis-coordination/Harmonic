import { describe, it, expect, beforeEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import HelloController from "./hello_controller"

describe("HelloController", () => {
  let application: Application

  beforeEach(() => {
    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="hello"></div>
    `

    // Start Stimulus application
    application = Application.start()
    application.register("hello", HelloController)
  })

  it("sets element text content to 'Hello World!' on connect", () => {
    const element = document.querySelector("[data-controller='hello']")
    expect(element?.textContent).toBe("Hello World!")
  })
})
