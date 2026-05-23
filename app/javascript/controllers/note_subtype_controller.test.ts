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
        <input type="hidden" name="subtype" value="post" data-note-subtype-target="subtypeInput">
        <button type="button" data-action="note-subtype#selectPost" data-note-subtype-target="postBtn" class="pulse-action-btn">Post</button>
        <button type="button" data-action="note-subtype#selectReminder" data-note-subtype-target="reminderBtn" class="pulse-action-btn-secondary">Reminder</button>
        <button type="button" data-action="note-subtype#selectTable" data-note-subtype-target="tableBtn" class="pulse-action-btn-secondary">Table</button>
        <div data-note-subtype-target="postFields">Post content</div>
        <div data-note-subtype-target="reminderFields" style="display: none;">Reminder fields</div>
        <div data-note-subtype-target="tableFields" style="display: none;">
          <div data-columns></div>
        </div>
      </form>
    `
  }

  it("shows post fields by default", async () => {
    renderForm()
    await waitForController()

    const postFields = document.querySelector("[data-note-subtype-target='postFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(postFields.style.display).toBe("")
    expect(tableFields.style.display).toBe("none")
  })

  it("switches to table mode when selectTable is called", async () => {
    renderForm()
    await waitForController()

    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLButtonElement
    tableBtn.click()

    const input = document.querySelector("[data-note-subtype-target='subtypeInput']") as HTMLInputElement
    const postFields = document.querySelector("[data-note-subtype-target='postFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(input.value).toBe("table")
    expect(postFields.style.display).toBe("none")
    expect(tableFields.style.display).toBe("")
  })

  it("switches back to post mode when selectPost is called", async () => {
    renderForm()
    await waitForController()

    // Switch to table first
    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLButtonElement
    tableBtn.click()

    // Switch back to post
    const postBtn = document.querySelector("[data-note-subtype-target='postBtn']") as HTMLButtonElement
    postBtn.click()

    const input = document.querySelector("[data-note-subtype-target='subtypeInput']") as HTMLInputElement
    const postFields = document.querySelector("[data-note-subtype-target='postFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(input.value).toBe("post")
    expect(postFields.style.display).toBe("")
    expect(tableFields.style.display).toBe("none")
  })

  it("toggles button classes on switch", async () => {
    renderForm()
    await waitForController()

    const postBtn = document.querySelector("[data-note-subtype-target='postBtn']") as HTMLElement
    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLElement

    // Initial state: post is primary
    expect(postBtn.className).toBe("pulse-action-btn")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")

    // Switch to table
    tableBtn.click()
    expect(postBtn.className).toBe("pulse-action-btn-secondary")
    expect(tableBtn.className).toBe("pulse-action-btn")

    // Switch back
    postBtn.click()
    expect(postBtn.className).toBe("pulse-action-btn")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")
  })

  it("addColumn appends a new column row", async () => {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="table" data-note-subtype-target="subtypeInput">
        <button type="button" data-note-subtype-target="postBtn" class="pulse-action-btn-secondary">Post</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="postFields" style="display: none;">Post</div>
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
        <button type="button" data-note-subtype-target="postBtn" class="pulse-action-btn-secondary">Post</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="postFields" style="display: none;">Post</div>
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

  it("switches to reminder mode when selectReminder is called", async () => {
    renderForm()
    await waitForController()

    const reminderBtn = document.querySelector("[data-note-subtype-target='reminderBtn']") as HTMLButtonElement
    reminderBtn.click()

    const input = document.querySelector("[data-note-subtype-target='subtypeInput']") as HTMLInputElement
    const postFields = document.querySelector("[data-note-subtype-target='postFields']") as HTMLElement
    const reminderFields = document.querySelector("[data-note-subtype-target='reminderFields']") as HTMLElement
    const tableFields = document.querySelector("[data-note-subtype-target='tableFields']") as HTMLElement

    expect(input.value).toBe("reminder")
    expect(postFields.style.display).toBe("none")
    expect(reminderFields.style.display).toBe("")
    expect(tableFields.style.display).toBe("none")
  })

  it("toggles all three button classes correctly", async () => {
    renderForm()
    await waitForController()

    const postBtn = document.querySelector("[data-note-subtype-target='postBtn']") as HTMLElement
    const reminderBtn = document.querySelector("[data-note-subtype-target='reminderBtn']") as HTMLElement
    const tableBtn = document.querySelector("[data-note-subtype-target='tableBtn']") as HTMLElement

    // Initial: post is active
    expect(postBtn.className).toBe("pulse-action-btn")
    expect(reminderBtn.className).toBe("pulse-action-btn-secondary")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")

    // Switch to reminder
    reminderBtn.click()
    expect(postBtn.className).toBe("pulse-action-btn-secondary")
    expect(reminderBtn.className).toBe("pulse-action-btn")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")

    // Switch to table
    tableBtn.click()
    expect(postBtn.className).toBe("pulse-action-btn-secondary")
    expect(reminderBtn.className).toBe("pulse-action-btn-secondary")
    expect(tableBtn.className).toBe("pulse-action-btn")

    // Switch back to post
    postBtn.click()
    expect(postBtn.className).toBe("pulse-action-btn")
    expect(reminderBtn.className).toBe("pulse-action-btn-secondary")
    expect(tableBtn.className).toBe("pulse-action-btn-secondary")
  })

  it("disables post textarea when switching to reminder", async () => {
    renderForm()
    await waitForController()

    const reminderBtn = document.querySelector("[data-note-subtype-target='reminderBtn']") as HTMLButtonElement
    reminderBtn.click()

    const postTextarea = document.querySelector("[data-note-subtype-target='postFields'] textarea") as HTMLTextAreaElement
    expect(postTextarea).toBeFalsy() // no textarea in our test fixture's postFields div, but let's test with one

    // Use a more realistic fixture
    document.body.innerHTML = ""
    application.stop()
    application = Application.start()
    application.register("note-subtype", NoteSubtypeController)

    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="post" data-note-subtype-target="subtypeInput">
        <button type="button" data-action="note-subtype#selectPost" data-note-subtype-target="postBtn" class="pulse-action-btn">Post</button>
        <button type="button" data-action="note-subtype#selectReminder" data-note-subtype-target="reminderBtn" class="pulse-action-btn-secondary">Reminder</button>
        <button type="button" data-action="note-subtype#selectTable" data-note-subtype-target="tableBtn" class="pulse-action-btn-secondary">Table</button>
        <div data-note-subtype-target="postFields"><textarea name="text">hello</textarea></div>
        <div data-note-subtype-target="reminderFields" style="display: none;"><textarea name="text"></textarea><input type="datetime-local" name="scheduled_for"></div>
        <div data-note-subtype-target="tableFields" style="display: none;"><div data-columns></div></div>
      </form>
    `
    await waitForController()

    // Initially post textarea should be enabled, reminder textarea disabled
    const postArea = document.querySelector("[data-note-subtype-target='postFields'] textarea") as HTMLTextAreaElement
    const reminderArea = document.querySelector("[data-note-subtype-target='reminderFields'] textarea") as HTMLTextAreaElement
    expect(postArea.disabled).toBe(false)
    expect(reminderArea.disabled).toBe(true)

    // Switch to reminder
    const remBtn = document.querySelector("[data-note-subtype-target='reminderBtn']") as HTMLButtonElement
    remBtn.click()
    expect(postArea.disabled).toBe(true)
    expect(reminderArea.disabled).toBe(false)

    // Switch back to post
    const pstBtn = document.querySelector("[data-note-subtype-target='postBtn']") as HTMLButtonElement
    pstBtn.click()
    expect(postArea.disabled).toBe(false)
    expect(reminderArea.disabled).toBe(true)
  })

  it("addColumn uses unique indices for field names", async () => {
    document.body.innerHTML = `
      <form data-controller="note-subtype">
        <input type="hidden" name="subtype" value="table" data-note-subtype-target="subtypeInput">
        <button type="button" data-note-subtype-target="postBtn" class="pulse-action-btn-secondary">Post</button>
        <button type="button" data-note-subtype-target="tableBtn" class="pulse-action-btn">Table</button>
        <div data-note-subtype-target="postFields" style="display: none;">Post</div>
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
