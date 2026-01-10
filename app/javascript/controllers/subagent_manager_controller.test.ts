import { describe, it, expect, beforeEach, vi, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import SubagentManagerController from "./subagent_manager_controller"

describe("SubagentManagerController", () => {
  let application: Application

  beforeEach(() => {
    // Mock fetch
    global.fetch = vi.fn()

    // Mock CSRF token
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="subagent-manager" data-subagent-manager-remove-url-value="/studio/settings/remove_subagent">
        <div data-subagent-manager-target="list">
          <table>
            <tbody>
              <tr data-subagent-id="1">
                <td><a href="/u/subagent1">Subagent One</a></td>
                <td><a href="/u/parent1">Parent One</a></td>
                <td>
                  <button type="button" class="button-small button-danger"
                          data-action="subagent-manager#remove"
                          data-subagent-id="1"
                          data-subagent-name="Subagent One"
                          data-remove-url="/studio/settings/remove_subagent">
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <form data-subagent-manager-target="addForm" data-action="submit->subagent-manager#add" action="/studio/settings/add_subagent">
          <select data-subagent-manager-target="select">
            <option value="">Select a subagent...</option>
            <option value="2">Subagent Two</option>
          </select>
          <button type="submit">Add</button>
        </form>
      </div>
    `

    application = Application.start()
    application.register("subagent-manager", SubagentManagerController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  describe("add", () => {
    it("sends POST request with selected subagent ID", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "2",
          subagent_name: "Subagent Two",
          subagent_path: "/u/subagent2",
          parent_name: "Parent Two",
          parent_path: "/u/parent2",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const select = document.querySelector("select") as HTMLSelectElement
      select.value = "2"

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      expect(fetch).toHaveBeenCalledWith(
        expect.stringContaining("/studio/settings/add_subagent"),
        expect.objectContaining({
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": "test-csrf-token",
            "Accept": "application/json",
          },
          body: JSON.stringify({ subagent_id: "2" }),
        })
      )
    })

    it("adds new row to table on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "2",
          subagent_name: "Subagent Two",
          subagent_path: "/u/subagent2",
          parent_name: "Parent Two",
          parent_path: "/u/parent2",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const initialRows = document.querySelectorAll("tbody tr").length

      const select = document.querySelector("select") as HTMLSelectElement
      select.value = "2"

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      await vi.waitFor(() => {
        const rows = document.querySelectorAll("tbody tr")
        expect(rows.length).toBe(initialRows + 1)
      })
    })

    it("removes option from select on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "2",
          subagent_name: "Subagent Two",
          subagent_path: "/u/subagent2",
          parent_name: "Parent Two",
          parent_path: "/u/parent2",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const select = document.querySelector("select") as HTMLSelectElement
      select.value = "2"

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      await vi.waitFor(() => {
        const option = document.querySelector("option[value='2']")
        expect(option).toBeNull()
      })
    })

    it("does not submit if no subagent selected", () => {
      const select = document.querySelector("select") as HTMLSelectElement
      select.value = ""

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      expect(fetch).not.toHaveBeenCalled()
    })
  })

  describe("remove", () => {
    it("shows confirmation dialog before removing", () => {
      const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false)

      const button = document.querySelector("button[data-action='subagent-manager#remove']") as HTMLButtonElement
      button.click()

      expect(confirmSpy).toHaveBeenCalledWith("Remove Subagent One from this studio?")
      expect(fetch).not.toHaveBeenCalled()
    })

    it("sends DELETE request when confirmed", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "1",
          subagent_name: "Subagent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='subagent-manager#remove']") as HTMLButtonElement
      button.click()

      expect(fetch).toHaveBeenCalledWith("/studio/settings/remove_subagent", {
        method: "DELETE",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": "test-csrf-token",
          "Accept": "application/json",
        },
        body: JSON.stringify({ subagent_id: "1" }),
      })
    })

    it("removes row from table on success", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "1",
          subagent_name: "Subagent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='subagent-manager#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const row = document.querySelector("tr[data-subagent-id='1']")
        expect(row).toBeNull()
      })
    })

    it("adds option back to select when can_readd is true", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          subagent_id: "1",
          subagent_name: "Subagent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='subagent-manager#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const option = document.querySelector("option[value='1']")
        expect(option).not.toBeNull()
        expect(option?.textContent).toBe("Subagent One")
      })
    })
  })
})
