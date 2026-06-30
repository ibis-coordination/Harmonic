import { describe, it, expect, beforeEach, vi, afterEach } from "vitest"
import { Application } from "@hotwired/stimulus"
import CollectiveMemberManagerController from "./collective_member_manager_controller"

describe("CollectiveMemberManagerController", () => {
  let application: Application

  beforeEach(() => {
    global.fetch = vi.fn()
    document.head.innerHTML = `<meta name="csrf-token" content="test-csrf-token">`

    document.body.innerHTML = `
      <div data-controller="collective-member-manager"
           data-collective-member-manager-update-roles-url-value="/collectives/team/members/update_roles"
           data-collective-member-manager-remove-url-value="/collectives/team/members/remove">
        <div class="pulse-participant" data-member-id="u1">
          <a href="/u/one">Member One</a>
          <div class="pulse-member-controls">
            <button type="button" class="pulse-role-toggle" aria-pressed="false"
                    data-action="collective-member-manager#toggleRole"
                    data-user-id="u1" data-role="admin" data-granted="false">admin</button>
            <button type="button" class="pulse-action-btn-danger pulse-member-remove"
                    data-action="collective-member-manager#remove"
                    data-user-id="u1" data-user-name="Member One">Remove</button>
          </div>
        </div>
      </div>
    `

    application = Application.start()
    application.register("collective-member-manager", CollectiveMemberManagerController)
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    document.body.innerHTML = ""
    document.head.innerHTML = ""
  })

  describe("toggleRole", () => {
    it("sends POST to grant the role when not currently granted", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({ user_id: "u1", role: "admin", granted: true, roles: ["admin"] }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-role='admin']") as HTMLButtonElement
      button.click()

      expect(fetch).toHaveBeenCalledWith(
        "/collectives/team/members/update_roles",
        expect.objectContaining({
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": "test-csrf-token",
            "Accept": "application/json",
          },
          body: JSON.stringify({ user_id: "u1", role: "admin", grant: true }),
        })
      )
    })

    it("marks the button active on success", async () => {
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({ user_id: "u1", role: "admin", granted: true, roles: ["admin"] }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-role='admin']") as HTMLButtonElement
      button.click()

      await vi.waitFor(() => {
        expect(button.classList.contains("is-active")).toBe(true)
        expect(button.dataset.granted).toBe("true")
        expect(button.getAttribute("aria-pressed")).toBe("true")
      })
    })

    it("alerts and leaves state unchanged on error", async () => {
      const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {})
      const mockResponse = {
        ok: false,
        json: () => Promise.resolve({ error: "Cannot remove the admin role from the last admin of this collective." }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-role='admin']") as HTMLButtonElement
      button.dataset.granted = "true"
      button.click()

      await vi.waitFor(() => {
        expect(alertSpy).toHaveBeenCalledWith("Cannot remove the admin role from the last admin of this collective.")
      })
      expect(button.dataset.granted).toBe("true")
    })
  })

  describe("remove", () => {
    it("shows confirmation before removing", () => {
      const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false)

      const button = document.querySelector("button[data-action='collective-member-manager#remove']") as HTMLButtonElement
      button.click()

      expect(confirmSpy).toHaveBeenCalledWith("Remove Member One from this collective?")
      expect(fetch).not.toHaveBeenCalled()
    })

    it("sends DELETE and removes the card on success", async () => {
      vi.spyOn(window, "confirm").mockReturnValue(true)
      const mockResponse = {
        ok: true,
        json: () => Promise.resolve({ user_id: "u1", user_name: "Member One" }),
      }
      vi.mocked(fetch).mockResolvedValue(mockResponse as Response)

      const button = document.querySelector("button[data-action='collective-member-manager#remove']") as HTMLButtonElement
      button.click()

      expect(fetch).toHaveBeenCalledWith(
        "/collectives/team/members/remove",
        expect.objectContaining({
          method: "DELETE",
          body: JSON.stringify({ user_id: "u1" }),
        })
      )

      await vi.waitFor(() => {
        expect(document.querySelector("[data-member-id='u1']")).toBeNull()
      })
    })
  })
})
