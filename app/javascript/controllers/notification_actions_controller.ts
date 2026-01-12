import { Controller } from "@hotwired/stimulus"

/**
 * NotificationActionsController handles AJAX actions for notifications:
 * - Mark individual notification as read
 * - Dismiss individual notification
 * - Mark all notifications as read
 *
 * Usage:
 * <div data-controller="notification-actions">
 *   <button data-action="click->notification-actions#markRead" data-notification-id="123">Mark read</button>
 *   <button data-action="click->notification-actions#dismiss" data-notification-id="123">Dismiss</button>
 *   <button data-action="click->notification-actions#markAllRead">Mark all read</button>
 * </div>
 */
export default class NotificationActionsController extends Controller<HTMLElement> {
  static targets = ["unreadCount", "markAllReadButton"]

  declare readonly unreadCountTarget: HTMLElement
  declare readonly hasUnreadCountTarget: boolean
  declare readonly markAllReadButtonTarget: HTMLElement
  declare readonly hasMarkAllReadButtonTarget: boolean

  private get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  async markRead(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLElement
    const notificationId = button.dataset.notificationId
    if (!notificationId) return

    const notificationItem = this.findNotificationItem(notificationId)

    try {
      const response = await fetch("/notifications/actions/mark_read", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
        body: `id=${encodeURIComponent(notificationId)}`,
      })

      if (response.ok) {
        // Hide the mark read button
        button.style.display = "none"
        // Dim the notification item
        if (notificationItem) {
          notificationItem.style.opacity = "0.6"
        }
        // Update unread count
        this.decrementUnreadCount()
        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      }
    } catch {
      // Silently fail - network errors shouldn't disrupt the user
    }
  }

  async dismiss(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLElement
    const notificationId = button.dataset.notificationId
    if (!notificationId) return

    const notificationItem = this.findNotificationItem(notificationId)

    try {
      const response = await fetch("/notifications/actions/dismiss", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
        body: `id=${encodeURIComponent(notificationId)}`,
      })

      if (response.ok) {
        // Remove the notification item from the list
        if (notificationItem) {
          notificationItem.remove()
        }
        // Update unread count (only if it wasn't already read)
        if (notificationItem && notificationItem.style.opacity !== "0.6") {
          this.decrementUnreadCount()
        }
        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      }
    } catch {
      // Silently fail
    }
  }

  async markAllRead(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLElement

    try {
      const response = await fetch("/notifications/actions/mark_all_read", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
      })

      if (response.ok) {
        // Hide the mark all read button
        button.style.display = "none"
        // Dim all notification items
        this.element.querySelectorAll("[data-notification-item]").forEach((item) => {
          ;(item as HTMLElement).style.opacity = "0.6"
        })
        // Hide all individual mark read buttons
        this.element.querySelectorAll("[data-action*='markRead']").forEach((btn) => {
          ;(btn as HTMLElement).style.display = "none"
        })
        // Update unread count to 0
        this.setUnreadCount(0)
        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      }
    } catch {
      // Silently fail
    }
  }

  private dispatchNotificationChange(): void {
    window.dispatchEvent(new CustomEvent("notifications:changed"))
  }

  private findNotificationItem(notificationId: string): HTMLElement | null {
    return this.element.querySelector(`[data-notification-item="${notificationId}"]`)
  }

  private decrementUnreadCount(): void {
    if (!this.hasUnreadCountTarget) return

    const currentText = this.unreadCountTarget.textContent || "0"
    const currentCount = parseInt(currentText, 10)
    const newCount = Math.max(0, currentCount - 1)
    this.setUnreadCount(newCount)
  }

  private setUnreadCount(count: number): void {
    if (this.hasUnreadCountTarget) {
      this.unreadCountTarget.textContent = count.toString()
    }

    // Update the summary text
    const summaryElement = this.element.querySelector("[data-notification-summary]")
    if (summaryElement) {
      if (count > 0) {
        summaryElement.innerHTML = `<strong>${count}</strong> unread notifications`
      } else {
        summaryElement.textContent = "No unread notifications"
      }
    }

    // Hide mark all read button when count is 0
    if (count === 0 && this.hasMarkAllReadButtonTarget) {
      this.markAllReadButtonTarget.style.display = "none"
    }
  }
}
