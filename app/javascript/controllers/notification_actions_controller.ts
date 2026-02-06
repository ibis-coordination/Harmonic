import { Controller } from "@hotwired/stimulus"

/**
 * NotificationActionsController handles AJAX actions for notifications:
 * - Dismiss individual notification
 * - Dismiss all notifications
 * - Dismiss all notifications for a specific studio
 *
 * Usage:
 * <div data-controller="notification-actions">
 *   <button data-action="click->notification-actions#dismiss" data-notification-id="123">Dismiss</button>
 *   <button data-action="click->notification-actions#dismissAll">Dismiss all</button>
 *   <button data-action="click->notification-actions#dismissForStudio" data-studio-id="456">Dismiss all for studio</button>
 * </div>
 */
export default class NotificationActionsController extends Controller<HTMLElement> {
  static targets = ["unreadCount", "dismissAllButton"]

  declare readonly unreadCountTarget: HTMLElement
  declare readonly hasUnreadCountTarget: boolean
  declare readonly dismissAllButtonTarget: HTMLElement
  declare readonly hasDismissAllButtonTarget: boolean

  private get csrfToken(): string {
    const meta = document.querySelector("meta[name='csrf-token']") as HTMLMetaElement | null
    return meta?.content ?? ""
  }

  async dismiss(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const notificationId = button.dataset.notificationId
    if (!notificationId) return

    const notificationItem = this.findNotificationItem(notificationId)
    const studioId = notificationItem?.dataset.studioId

    // Disable button while loading
    button.disabled = true

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

        // Check if the accordion group is now empty and remove it
        if (studioId) {
          const groupElement = this.element.querySelector(`[data-superagent-group="${studioId}"]`)
          if (groupElement) {
            const remainingItems = groupElement.querySelectorAll("[data-notification-item]")
            if (remainingItems.length === 0) {
              groupElement.remove()
            } else {
              // Update the count in the accordion header
              const countElement = groupElement.querySelector(".pulse-accordion-count")
              if (countElement) {
                countElement.textContent = `(${remainingItems.length})`
              }
            }
          }
        }

        // Update unread count
        this.decrementUnreadCount()
        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      } else {
        // Server error - re-enable button so user can retry
        button.disabled = false
      }
    } catch {
      // Network error - re-enable button so user can retry
      button.disabled = false
    }
  }

  async dismissAll(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const originalText = button.textContent

    // Show loading state
    button.disabled = true
    button.textContent = "Dismissing..."

    try {
      const response = await fetch("/notifications/actions/dismiss_all", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
      })

      if (response.ok) {
        // Hide the dismiss all button
        button.style.display = "none"
        // Remove all notification items
        this.element.querySelectorAll("[data-notification-item]").forEach((item) => {
          item.remove()
        })
        // Remove all accordion groups
        this.element.querySelectorAll("[data-superagent-group]").forEach((item) => {
          item.remove()
        })
        // Update unread count to 0
        this.setUnreadCount(0)
        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      } else {
        // Server error - restore button so user can retry
        button.disabled = false
        button.textContent = originalText
      }
    } catch {
      // Network error - restore button so user can retry
      button.disabled = false
      button.textContent = originalText
    }
  }

  async dismissForStudio(event: Event): Promise<void> {
    event.preventDefault()
    event.stopPropagation() // Prevent accordion toggle

    const button = event.currentTarget as HTMLButtonElement
    const studioId = button.dataset.studioId
    if (!studioId) return

    const originalText = button.textContent

    // Show loading state
    button.disabled = true
    button.textContent = "Dismissing..."

    try {
      const response = await fetch("/notifications/actions/dismiss_for_studio", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
          Accept: "application/json",
        },
        body: `studio_id=${encodeURIComponent(studioId)}`,
      })

      if (response.ok) {
        const data = (await response.json()) as { count?: number }
        const dismissedCount = data.count ?? 0

        // Remove all notification items in this studio group
        const groupElement = this.element.querySelector(`[data-superagent-group="${studioId}"]`)
        if (groupElement) {
          groupElement.remove()
        }

        // Update unread count
        this.decrementUnreadCountBy(dismissedCount)

        // If no more groups, hide dismiss all button
        const remainingGroups = this.element.querySelectorAll("[data-superagent-group]")
        if (remainingGroups.length === 0 && this.hasDismissAllButtonTarget) {
          this.dismissAllButtonTarget.style.display = "none"
        }

        // Notify badge controller to refresh
        this.dispatchNotificationChange()
      } else {
        // Server error - restore button so user can retry
        button.disabled = false
        button.textContent = originalText
      }
    } catch {
      // Network error - restore button so user can retry
      button.disabled = false
      button.textContent = originalText
    }
  }

  private dispatchNotificationChange(): void {
    window.dispatchEvent(new CustomEvent("notifications:changed"))
  }

  private findNotificationItem(notificationId: string): HTMLElement | null {
    return this.element.querySelector(`[data-notification-item="${notificationId}"]`)
  }

  private decrementUnreadCount(): void {
    this.decrementUnreadCountBy(1)
  }

  private decrementUnreadCountBy(amount: number): void {
    if (!this.hasUnreadCountTarget) return

    const currentText = this.unreadCountTarget.textContent || "0"
    const currentCount = parseInt(currentText, 10)
    const newCount = Math.max(0, currentCount - amount)
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

    // Hide dismiss all button when count is 0
    if (count === 0 && this.hasDismissAllButtonTarget) {
      this.dismissAllButtonTarget.style.display = "none"
    }
  }
}
