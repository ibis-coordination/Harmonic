import { Controller } from "@hotwired/stimulus"

/**
 * NotificationBadgeController polls the server for the current unread notification count
 * and updates the badge display accordingly.
 *
 * Usage:
 * <div data-controller="notification-badge" data-notification-badge-poll-interval-value="30000">
 *   <span data-notification-badge-target="count">0</span>
 * </div>
 */
export default class NotificationBadgeController extends Controller<HTMLElement> {
  static targets = ["count"]
  static values = {
    pollInterval: { type: Number, default: 30000 }, // Default: 30 seconds
  }

  declare readonly countTarget: HTMLElement
  declare readonly hasCountTarget: boolean
  declare pollIntervalValue: number

  private pollTimer: number | null = null

  connect(): void {
    // Fetch immediately on connect to initialize page title and counts
    this.fetchUnreadCount()
    this.startPolling()
    // Listen for notification changes from other controllers
    window.addEventListener("notifications:changed", this.handleNotificationChange)
  }

  disconnect(): void {
    this.stopPolling()
    window.removeEventListener("notifications:changed", this.handleNotificationChange)
  }

  private handleNotificationChange = (): void => {
    this.fetchUnreadCount()
  }

  private startPolling(): void {
    if (this.pollIntervalValue > 0) {
      this.pollTimer = window.setInterval(() => {
        this.fetchUnreadCount()
      }, this.pollIntervalValue)
    }
  }

  private stopPolling(): void {
    if (this.pollTimer !== null) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  private async fetchUnreadCount(): Promise<void> {
    try {
      const response = await fetch("/notifications/unread_count", {
        headers: {
          Accept: "application/json",
        },
        credentials: "same-origin",
      })

      if (!response.ok) {
        return
      }

      const data = await response.json()
      this.updateBadge(data.count)
    } catch {
      // Silently fail - network errors shouldn't disrupt the user
    }
  }

  private updateBadge(count: number): void {
    if (this.hasCountTarget) {
      this.countTarget.textContent = count.toString()

      if (count > 0) {
        this.countTarget.style.display = ""
      } else {
        this.countTarget.style.display = "none"
      }
    }

    this.updatePageTitle(count)
  }

  private updatePageTitle(count: number): void {
    // Remove any existing count prefix like "(3) "
    const baseTitle = document.title.replace(/^\(\d+\)\s*/, "")

    if (count > 0) {
      document.title = `(${count}) ${baseTitle}`
    } else {
      document.title = baseTitle
    }
  }
}
