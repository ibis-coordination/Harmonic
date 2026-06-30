import { Controller } from "@hotwired/stimulus"
import { fetchWithCsrf } from "../utils/csrf"

// Admin-only controls on the collective members page. Grants/revokes roles on a
// member and removes members from the collective, updating the DOM in place.
// Mirrors the JSON contract of CollectivesController#update_member_roles and
// #remove_member.
export default class CollectiveMemberManagerController extends Controller {
  static values = { updateRolesUrl: String, removeUrl: String, roleOrder: Array }

  declare readonly updateRolesUrlValue: string
  declare readonly removeUrlValue: string
  declare readonly roleOrderValue: string[]

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
      .then((data: { granted: boolean; roles: string[] }) => {
        this.applyRoleState(button, role, data.granted)
        // Reflect the authoritative role set the server returned: rebuild this
        // member's pill row so admins can see who holds what at a glance.
        this.renderRolePills(userId, data.roles)
        // The action succeeded — collapse the menu so the result is visible.
        this.closeMenu(button)
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

  // Reflect the new role state on the kebab menu item: the label flips between
  // "Add role X" and "Remove role X" so the next click does the opposite.
  private applyRoleState(button: HTMLButtonElement, role: string, granted: boolean): void {
    button.dataset.granted = granted ? "true" : "false"
    button.textContent = granted ? `Remove role ${role}` : `Add role ${role}`
  }

  // Rebuild the member's role pills from the server's authoritative role list,
  // ordered by roleOrderValue so the row stays stable as roles are toggled.
  private renderRolePills(userId: string, roles: string[]): void {
    const container = this.element.querySelector(`[data-role-pills-for="${userId}"]`)
    if (!container) return

    const ordered = this.roleOrderValue.filter((role) => roles.includes(role))
    const pills = ordered.map((role) => {
      const pill = document.createElement("span")
      pill.className = "pulse-badge pulse-badge-muted"
      pill.dataset.rolePill = role
      pill.textContent = role
      return pill
    })
    container.replaceChildren(...pills)
  }

  // Collapse the kebab <details> menu the clicked item lives in.
  private closeMenu(button: HTMLButtonElement): void {
    const menu = button.closest("details")
    if (menu) (menu as HTMLDetailsElement).open = false
  }

  private removeMemberCard(userId: string): void {
    const card = this.element.querySelector(`[data-member-id="${userId}"]`)
    if (card) card.remove()
  }
}
