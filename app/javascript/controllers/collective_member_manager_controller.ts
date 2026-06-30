import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

// Admin-only controls on the collective members page. Grants/revokes roles on a
// member and removes members from the collective, updating the DOM in place.
// Mirrors the JSON contract of CollectivesController#update_member_roles and
// #remove_member.
export default class CollectiveMemberManagerController extends Controller {
  static values = { updateRolesUrl: String, removeUrl: String }

  declare readonly updateRolesUrlValue: string
  declare readonly removeUrlValue: string

  toggleRole(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const userId = button.dataset.userId
    const role = button.dataset.role
    if (!userId || !role) return

    const currentlyGranted = button.dataset.granted === "true"
    const grant = !currentlyGranted

    button.disabled = true

    fetchWithCsrf(this.updateRolesUrlValue, {
      method: "POST",
      headers: { Accept: "application/json" },
      body: JSON.stringify({ user_id: userId, role, grant }),
    })
      .then(async (response) => {
        if (response.ok) return response.json()
        const data = await response.json().catch(() => ({}))
        throw new Error(data.error || "Failed to update role")
      })
      .then((data: { granted: boolean }) => {
        this.applyRoleState(button, data.granted)
      })
      .catch((error: Error) => {
        console.error("Error updating member role:", error)
        alert(error.message)
      })
      .finally(() => {
        button.disabled = false
      })
  }

  remove(event: Event): void {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const userId = button.dataset.userId
    const userName = button.dataset.userName || "this member"
    if (!userId) return

    if (!confirm(`Remove ${userName} from this collective?`)) return

    button.disabled = true

    fetchWithCsrf(this.removeUrlValue, {
      method: "DELETE",
      headers: { Accept: "application/json" },
      body: JSON.stringify({ user_id: userId }),
    })
      .then(async (response) => {
        if (response.ok) return response.json()
        const data = await response.json().catch(() => ({}))
        throw new Error(data.error || "Failed to remove member")
      })
      .then(() => {
        this.removeMemberCard(userId)
      })
      .catch((error: Error) => {
        console.error("Error removing member:", error)
        alert(error.message)
        button.disabled = false
      })
  }

  private applyRoleState(button: HTMLButtonElement, granted: boolean): void {
    button.dataset.granted = granted ? "true" : "false"
    button.setAttribute("aria-pressed", granted ? "true" : "false")
    button.classList.toggle("is-active", granted)
  }

  private removeMemberCard(userId: string): void {
    const card = this.element.querySelector(`[data-member-id="${userId}"]`)
    if (card) card.remove()
  }
}
