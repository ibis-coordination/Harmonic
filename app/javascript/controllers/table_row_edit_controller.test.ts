import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import TableRowEditController from "./table_row_edit_controller"

describe("TableRowEditController", () => {
  let application: Application

  beforeEach(() => {
    application = Application.start()
    application.register("table-row-edit", TableRowEditController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    vi.restoreAllMocks()
  })

  function mount() {
    document.body.innerHTML = `
      <table><tbody>
        <tr data-controller="table-row-edit">
          <td>
            <span data-table-row-edit-target="display">pending</span>
            <input data-table-row-edit-target="input" name="values[Status]" value="pending" hidden>
          </td>
          <td>
            <button data-table-row-edit-target="editButton" data-action="table-row-edit#edit">Edit</button>
            <button data-table-row-edit-target="saveButton" type="submit" form="update-row-x" hidden>Save</button>
            <button data-table-row-edit-target="cancelButton" data-action="table-row-edit#cancel" hidden>Cancel</button>
            <button data-table-row-edit-target="deleteButton">Delete</button>
          </td>
        </tr>
      </tbody></table>
    `
  }

  const el = (sel: string) => document.querySelector(sel) as HTMLElement
  const display = () => el("[data-table-row-edit-target='display']")
  const input = () => el("[data-table-row-edit-target='input']") as HTMLInputElement
  const editBtn = () => el("[data-table-row-edit-target='editButton']") as HTMLButtonElement
  const saveBtn = () => el("[data-table-row-edit-target='saveButton']")
  const cancelBtn = () => el("[data-table-row-edit-target='cancelButton']") as HTMLButtonElement
  const deleteBtn = () => el("[data-table-row-edit-target='deleteButton']")

  it("starts in display mode: inputs and save/cancel hidden, display and edit/delete shown", async () => {
    mount()
    await new Promise((r) => setTimeout(r, 0))
    expect(display().hidden).toBe(false)
    expect(input().hidden).toBe(true)
    expect(editBtn().hidden).toBe(false)
    expect(deleteBtn().hidden).toBe(false)
    expect(saveBtn().hidden).toBe(true)
    expect(cancelBtn().hidden).toBe(true)
  })

  it("Edit reveals inputs and save/cancel, hides display and edit/delete", async () => {
    mount()
    await new Promise((r) => setTimeout(r, 0))
    editBtn().click()
    expect(display().hidden).toBe(true)
    expect(input().hidden).toBe(false)
    expect(editBtn().hidden).toBe(true)
    expect(deleteBtn().hidden).toBe(true)
    expect(saveBtn().hidden).toBe(false)
    expect(cancelBtn().hidden).toBe(false)
  })

  it("Cancel restores display mode and discards edits", async () => {
    mount()
    await new Promise((r) => setTimeout(r, 0))
    editBtn().click()
    input().value = "edited but abandoned"
    cancelBtn().click()
    expect(input().value).toBe("pending") // reset to server-rendered value
    expect(display().hidden).toBe(false)
    expect(input().hidden).toBe(true)
    expect(saveBtn().hidden).toBe(true)
    expect(editBtn().hidden).toBe(false)
  })
})
