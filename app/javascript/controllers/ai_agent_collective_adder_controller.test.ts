import { describe, it, expect, beforeEach, vi, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import AiAgentCollectiveAdderController from "./ai_agent_collective_adder_controller"

describe("AiAgentCollectiveAdderController", () => {
  let application: Application

  beforeEach(() => {
    // Mock fetch
    global.fetch = vi.fn()

    // Mock CSRF token
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="ai_agent-collective-adder" data-ai_agent-collective-adder-remove-url-value="/u/ai_agent1/remove_from_studio">
        <ul class="studio-membership-list" data-ai_agent-collective-adder-target="collectiveList">
          <li class="studio-item" data-collective-id="1">
            <a href="/studios/studio1">Studio One</a>
            <button type="button" class="button-small button-danger"
                    data-action="ai_agent-collective-adder#remove"
                    data-collective-id="1"
                    data-collective-name="Studio One">
              Remove from studio
            </button>
          </li>
        </ul>
        <form data-ai_agent-collective-adder-target="form" data-action="submit->ai_agent-collective-adder#add" action="/u/ai_agent1/add_to_studio">
          <select data-ai_agent-collective-adder-target="select">
            <option value="">Add to studio...</option>
            <option value="2">Studio Two</option>
          </select>
          <button type="submit">Add</button>
        </form>
      </div>
    `

    application = Application.start()
    application.register("ai_agent-collective-adder", AiAgentCollectiveAdderController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  describe("add", () => {
    it("sends POST request with selected studio ID", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 2,
          collective_name: "Studio Two",
          collective_path: "/studios/studio2",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const select = document.querySelector("select") as HTMLSelectElement
      select.value = "2"

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      expect(fetch).toHaveBeenCalledWith(
        expect.stringContaining("/u/ai_agent1/add_to_studio"),
        expect.objectContaining({
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": "test-csrf-token",
            "Accept": "application/json",
          },
          body: JSON.stringify({ collective_id: "2" }),
        })
      )
    })

    it("adds new item to list on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 2,
          collective_name: "Studio Two",
          collective_path: "/studios/studio2",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const initialItems = document.querySelectorAll(".studio-item").length

      const select = document.querySelector("select") as HTMLSelectElement
      select.value = "2"

      const form = document.querySelector("form") as HTMLFormElement
      form.dispatchEvent(new Event("submit", { bubbles: true }))

      await vi.waitFor(() => {
        const items = document.querySelectorAll(".studio-item")
        expect(items.length).toBe(initialItems + 1)
      })
    })

    it("removes option from select on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 2,
          collective_name: "Studio Two",
          collective_path: "/studios/studio2",
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

    it("does not submit if no studio selected", () => {
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

      const button = document.querySelector("button[data-action='ai_agent-collective-adder#remove']") as HTMLButtonElement
      button.click()

      expect(confirmSpy).toHaveBeenCalledWith("Remove this ai_agent from Studio One?")
      expect(fetch).not.toHaveBeenCalled()
    })

    it("sends DELETE request when confirmed", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 1,
          collective_name: "Studio One",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-collective-adder#remove']") as HTMLButtonElement
      button.click()

      expect(fetch).toHaveBeenCalledWith("/u/ai_agent1/remove_from_studio", {
        method: "DELETE",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": "test-csrf-token",
          "Accept": "application/json",
        },
        body: JSON.stringify({ collective_id: "1" }),
      })
    })

    it("removes item from list on success", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 1,
          collective_name: "Studio One",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-collective-adder#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const item = document.querySelector(".studio-item[data-collective-id='1']")
        expect(item).toBeNull()
      })
    })

    it("shows 'None' message when last studio removed", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 1,
          collective_name: "Studio One",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-collective-adder#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const noneMessage = document.querySelector(".none-message")
        expect(noneMessage).not.toBeNull()
        expect(noneMessage?.textContent).toContain("Not a member of any studios")
      })
    })

    it("adds option back to select on success", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({
          collective_id: 1,
          collective_name: "Studio One",
        }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='ai_agent-collective-adder#remove']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        const option = document.querySelector("option[value='1']")
        expect(option).not.toBeNull()
        expect(option?.textContent).toBe("Studio One")
      })
    })
  })
})
