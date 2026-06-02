import { Controller } from "@hotwired/stimulus"

/**
 * ListFormController enforces UserList constraints in the new/edit form:
 *
 *   - When visibility = "private", add_policy MUST be "owner_only" (server
 *     also rejects other combinations). We auto-set the value and disable
 *     the non-owner_only options so the user can't pick a doomed combo.
 *   - When visibility = "public", all add_policy options are enabled.
 *
 * Stays in sync on connect (so server-rendered errors don't drop into a
 * stale option set) and on every visibility change.
 */
export default class ListFormController extends Controller<HTMLElement> {
  static targets = ["visibility", "addPolicy"]

  declare readonly visibilityTarget: HTMLSelectElement
  declare readonly addPolicyTarget: HTMLSelectElement

  connect(): void {
    this.sync()
  }

  sync(): void {
    const isPrivate = this.visibilityTarget.value === "private"

    if (isPrivate && this.addPolicyTarget.value !== "owner_only") {
      this.addPolicyTarget.value = "owner_only"
    }

    Array.from(this.addPolicyTarget.options).forEach((opt) => {
      opt.disabled = isPrivate && opt.value !== "owner_only"
    })
  }
}
