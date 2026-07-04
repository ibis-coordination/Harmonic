import { Controller } from "@hotwired/stimulus"

/**
 * PlacesBadgesController fills the places sheet's and tab bar's unread
 * badges. It does no fetching of its own: NotificationBadgeController polls
 * /notifications/unread_count and broadcasts "notifications:counts" with the
 * per-collective breakdown; this controller just projects that onto the
 * .pulse-places-badge elements.
 *
 * Usage:
 * <nav class="pulse-places-nav" data-controller="places-badges">
 *   <span class="pulse-places-badge" data-collective-id="..." style="display: none"></span>
 * </nav>
 */
export default class PlacesBadgesController extends Controller<HTMLElement> {
  connect(): void {
    window.addEventListener("notifications:counts", this.handleCounts)
  }

  disconnect(): void {
    window.removeEventListener("notifications:counts", this.handleCounts)
  }

  private handleCounts = (event: Event): void => {
    const detail = (event as CustomEvent).detail
    const byCollective: Record<string, number> = detail?.byCollective ?? {}

    this.element
      .querySelectorAll<HTMLElement>(".pulse-places-badge[data-collective-id]")
      .forEach((badge) => {
        this.updateBadge(badge, byCollective[badge.dataset.collectiveId ?? ""] ?? 0)
      })

    const chatBadge = this.element.querySelector<HTMLElement>(".pulse-places-badge[data-chat-badge]")
    if (chatBadge) {
      this.updateBadge(chatBadge, detail?.chat ?? 0)
    }

    // Total unread count — the tab bar's inbox badge.
    const totalBadge = this.element.querySelector<HTMLElement>("[data-total-badge]")
    if (totalBadge) {
      this.updateBadge(totalBadge, detail?.count ?? 0)
    }
  }

  private updateBadge(badge: HTMLElement, count: number): void {
    if (count > 0) {
      badge.textContent = count > 99 ? "99+" : count.toString()
      badge.style.display = ""
    } else {
      badge.textContent = ""
      badge.style.display = "none"
    }
    this.updateEntryHref(badge, count)
  }

  // A badged place entry links to its feed filtered to what the viewer was
  // notified about; unbadged it links plainly. Entries without a
  // data-place-path (chat — not a feed) never swap. Mirrors
  // UnreadBadgeDisplay#place_entry_href — keep the two in sync.
  private updateEntryHref(badge: HTMLElement, count: number): void {
    const anchor = badge.closest<HTMLAnchorElement>("a[data-place-path]")
    if (!anchor) return

    const basePath = anchor.dataset.placePath ?? ""
    anchor.setAttribute("href", count > 0 ? `${basePath}?q=my:notified` : basePath)
  }
}
