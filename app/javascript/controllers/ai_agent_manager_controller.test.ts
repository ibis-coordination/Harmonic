import { describe, it, expect, beforeEach, vi, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import AiAgentManagerController from "./ai_agent_manager_controller"

describe("AiAgentManagerController", () => {
  let application: Application

  beforeEach(() => {
    // Mock fetch
    global.fetch = vi.fn()

    // Mock CSRF token
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="ai_agent-manager" data-ai_agent-manager-remove-url-value="/studio/settings/remove_ai_agent">
        <div data-ai_agent-manager-target="list">
          <table>
            <tbody>
              <tr data-ai_agent-id="1">
                <td><a href="/u/ai_agent1">AiAgent One</a></td>
                <td><a href="/u/parent1">Parent One</a></td>
                <td>
                  <button type="button" class="button-small button-danger"
                          data-action="ai_agent-manager#remove"
                          data-ai_agent-id="1"
                          data-ai_agent-name="AiAgent One"
                          data-remove-url="/studio/settings/remove_ai_agent">
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <form data-ai_agent-manager-target="addForm" data-action="submit->ai_agent-manager#add" action="/studio/settings/add_ai_agent">
          <select data-ai_agent-manager-target="select">
            <option value="">Select a ai_agent...</option>
            <option value="2">AiAgent Two</option>
          </select>
          <button type="submit">Add</button>
        </form>
      </div>
    `

    application = Application.start()
    application.register("ai_agent-manager", AiAgentManagerController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  describe("add", () => {
    it("sends POST request with selected ai_agent ID", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          ai_agent_id: "2",
          ai_agent_name: "AiAgent Two",
          ai_agent_path: "/u/ai_agent2",
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
        expect.stringContaining("/studio/settings/add_ai_agent"),
        expect.objectContaining({
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": "test-csrf-token",
            "Accept": "application/json",
          },
          body: JSON.stringify({ ai_agent_id: "2" }),
        })
      )
    })

    it("adds new row to table on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          ai_agent_id: "2",
          ai_agent_name: "AiAgent Two",
          ai_agent_path: "/u/ai_agent2",
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
          ai_agent_id: "2",
          ai_agent_name: "AiAgent Two",
          ai_agent_path: "/u/ai_agent2",
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

    it("does not submit if no ai_agent selected", () => {
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

      const button = document.querySelector("button[data-action='ai_agent-manager#remove']") as HTMLButtonElement
      button.click()

      expect(confirmSpy).toHaveBeenCalledWith("Remove AiAgent One from this studio?")
      expect(fetch).not.toHaveBeenCalled()
    })

    it("sends DELETE request when confirmed", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          ai_agent_id: "1",
          ai_agent_name: "AiAgent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-manager#remove']") as HTMLButtonElement
      button.click()

      expect(fetch).toHaveBeenCalledWith("/studio/settings/remove_ai_agent", {
        method: "DELETE",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": "test-csrf-token",
          "Accept": "application/json",
        },
        body: JSON.stringify({ ai_agent_id: "1" }),
      })
    })

    it("removes row from table on success", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          ai_agent_id: "1",
          ai_agent_name: "AiAgent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-manager#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const row = document.querySelector("tr[data-ai_agent-id='1']")
        expect(row).toBeNull()
      })
    })

    it("adds option back to select when can_readd is true", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          ai_agent_id: "1",
          ai_agent_name: "AiAgent One",
          can_readd: true,
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-manager#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const option = document.querySelector("option[value='1']")
        expect(option).not.toBeNull()
        expect(option?.textContent).toBe("AiAgent One")
      })
    })
  })
})
