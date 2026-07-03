import { Controller } from "@hotwired/stimulus"

/**
 * RailBadgesController fills the collective rail's per-square unread badges.
 * It does no fetching of its own: NotificationBadgeController polls
 * /notifications/unread_count and broadcasts "notifications:counts" with the
 * per-collective breakdown; this controller just projects that onto the
 * .pulse-rail-badge elements.
 *
 * Usage:
 * <nav class="pulse-rail" data-controller="rail-badges">
 *   <span class="pulse-rail-badge" data-collective-id="..." style="display: none"></span>
 * </nav>
 */
export default class RailBadgesController extends Controller<HTMLElement> {
  connect(): void {
    window.addEventListener("notifications:counts", this.handleCounts)
  }

  disconnect(): void {
    window.removeEventListener("notifications:counts", this.handleCounts)
  }

  private handleCounts = (event: Event): void => {
    const byCollective: Record<string, number> =
      (event as CustomEvent).detail?.byCollective ?? {}

    this.element
      .querySelectorAll<HTMLElement>(".pulse-rail-badge[data-collective-id]")
      .forEach((badge) => {
        const count = byCollective[badge.dataset.collectiveId ?? ""] ?? 0
        if (count > 0) {
          badge.textContent = count > 99 ? "99+" : count.toString()
          badge.style.display = ""
        } else {
          badge.textContent = ""
          badge.style.display = "none"
        }
      })
  }
}
