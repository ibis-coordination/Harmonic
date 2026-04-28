import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import NoteSubtypeController from "./note_subtype_controller"
import { waitForController } from "../test/setup"

describe("NoteSubtypeController", () => {
  let application: Application

  beforeEach(() => {
    document.body.innerHTML = ""
    application = Application.start()
    application.register("note-subtype", NoteSubtypeController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  function renderForm() {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="text" data-note-subtype-target="subtypeInput">
        <button type="button" data-action="note-subtype#selectText" data-note-subtype-target="textBtn" class="pulse-action-btn">Text</button>
        <button type="button" data-action="note-subtype#selectTable" data-note-subtype-target="tableBtn" class="pulse-action-btn-secondary">Table</button>
        <div data-note-subtype-target="textFields">Text content</div>
        <div data-note-subtype-target="tableFields" style="display: none;">
          <div data-columns></div>
        </div>
      </form>
    `
  }

  it("shows text fields by default", async () => {
    renderForm()
    await waitForController()

    const textFields = document.querySelector("[data-note-subtype-target='textFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(textFields.style.display).toBe("")
    expect(tableFields.style.display).toBe("none")
  })

  it("switches to table mode when selectTable is called", async () => {
    renderForm()
    await waitForController()

    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLButtonElement
    tableBtn.click()

    const input = document.querySelector("[data-note-subtype-target='subtypeInput']") as HTMLInputElement
    const textFields = document.querySelector("[data-note-subtype-target='textFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(input.value).toBe("table")
    expect(textFields.style.display).toBe("none")
    expect(tableFields.style.display).toBe("")
  })

  it("switches back to text mode when selectText is called", async () => {
    renderForm()
    await waitForController()

    // Switch to table first
    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLButtonElement
    tableBtn.click()

    // Switch back to text
    const textBtn = document.querySelector("[data-note-subtype-target='textBtn']") as HTMLButtonElement
    textBtn.click()

    const input = document.querySelector("[data-note-subtype-target='subtypeInput']") as HTMLInputElement
    const textFields = document.querySelector("[data-note-subtype-target='textFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(input.value).toBe("text")
    expect(textFields.style.display).toBe("")
    expect(tableFields.style.display).toBe("none")
  })

  it("toggles button classes on switch", async () => {
    renderForm()
    await waitForController()

    const textBtn = document.querySelector("[data-note-subtype-target='textBtn']") as HTMLElement
    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLElement

    // Initial state: text is primary
    expect(textBtn.className).toBe("pulse-action-btn")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")

    // Switch to table
    tableBtn.click()
    expect(textBtn.className).toBe("pulse-action-btn-secondary")
    expect(tableBtn.className).toBe("pulse-action-btn")

    // Switch back
    textBtn.click()
    expect(textBtn.className).toBe("pulse-action-btn")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")
  })

  it("addColumn appends a new column row", async () => {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="table" data-note-subtype-target="subtypeInput">
        <button type="button" data-note-subtype-target="textBtn" class="pulse-action-btn-secondary">Text</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="textFields" style="display: none;">Text</div>
        <div data-note-subtype-target="tableFields">
          <div data-columns></div>
          <button type="button" data-action="note-subtype#addColumn">Add</button>
        </div>
      </form>
    `
    await waitForController()

    const container = document.querySelector("[data-columns]") as HTMLElement
    expect(container.children.length).toBe(0)

    const addBtn = document.querySelector("[data-action='note-subtype#addColumn']") as HTMLButtonElement
    addBtn.click()

    expect(container.children.length).toBe(1)
    const nameInput = container.querySelector("input[type='text']") as HTMLInputElement
    expect(nameInput).toBeTruthy()
    expect(nameInput.placeholder).toBe("Column name")

    const select = container.querySelector("select") as HTMLSelectElement
    expect(select).toBeTruthy()
    expect(select.options.length).toBe(4)
  })

  it("removeColumn removes the column row", async () => {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="table" data-note-subtype-target="subtypeInput">
        <button type="button" data-note-subtype-target="textBtn" class="pulse-action-btn-secondary">Text</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="textFields" style="display: none;">Text</div>
        <div data-note-subtype-target="tableFields">
          <div data-columns>
            <div>
              <input type="text" name="columns[0][name]" value="Status">
              <button type="button" data-action="note-subtype#removeColumn">✕</button>
            </div>
            <div>
              <input type="text" name="columns[1][name]" value="Due">
              <button type="button" data-action="note-subtype#removeColumn">✕</button>
            </div>
          </div>
        </div>
      </form>
    `
    await waitForController()

    const container = document.querySelector("[data-columns]") as HTMLElement
    expect(container.children.length).toBe(2)

    const removeBtn = container.querySelector("[data-action='note-subtype#removeColumn']") as HTMLButtonElement
    removeBtn.click()

    expect(container.children.length).toBe(1)
  })

  it("addColumn uses unique indices for field names", async () => {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="table" data-note-subtype-target="subtypeInput">
        <button type="button" data-note-subtype-target="textBtn" class="pulse-action-btn-secondary">Text</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="textFields" style="display: none;">Text</div>
        <div data-note-subtype-target="tableFields">
          <div data-columns></div>
          <button type="button" data-action="note-subtype#addColumn">Add</button>
        </div>
      </form>
    `
    await waitForController()

    const addBtn = document.querySelector("[data-action='note-subtype#addColumn']") as HTMLButtonElement
    addBtn.click()
    addBtn.click()

    const inputs = document.querySelectorAll("[data-columns] input[type='text']")
    const names = Array.from(inputs).map((i) => (i as HTMLInputElement).name)

    // Each should have a unique index (timestamp-based, so different)
    const indices = names.map((n) => n.match(/columns\[(\d+)\]/)![1])
    expect(new Set(indices).size).toBe(2)
  })
})
