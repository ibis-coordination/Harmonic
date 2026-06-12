import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

/**
 * NotificationActionsController handles AJAX actions for notifications:
 * - Dismiss individual notification (removes the row)
 * - Dismiss all notifications / all for a specific collective
 * - Mark individual notification read (row stays, loses unread styling)
 * - Mark all read / all for a specific collective
 * - Mark read on click-through (keepalive request alongside navigation)
 *
 * Usage:
 * <div data-controller="notification-actions">
 *   <button data-action="click->notification-actions#dismiss" data-notification-id="123">Dismiss</button>
 *   <button data-action="click->notification-actions#dismissAll">Dismiss all</button>
 *   <button data-action="click->notification-actions#dismissForCollective" data-collective-id="456">Dismiss all for collective</button>
 *   <button data-mark-read-button data-action="click->notification-actions#markRead" data-notification-id="123">Mark read</button>
 *   <button data-action="click->notification-actions#markAllRead">Mark all read</button>
 *   <button data-action="click->notification-actions#markReadForCollective" data-collective-id="456">Mark all read for collective</button>
 *   <a href="/n/abc" data-action="click->notification-actions#markReadOnNavigate" data-notification-id="123">Title</a>
 * </div>
 */
export default class NotificationActionsController extends Controller<HTMLElement> {
  static targets = ["unreadCount", "dismissAllButton", "markAllReadButton"]

  declare readonly unreadCountTarget: HTMLElement
  declare readonly hasUnreadCountTarget: boolean
  declare readonly dismissAllButtonTarget: HTMLElement
  declare readonly hasDismissAllButtonTarget: boolean
  declare readonly markAllReadButtonTarget: HTMLElement
  declare readonly hasMarkAllReadButtonTarget: boolean

  async dismiss(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const notificationId = button.dataset.notificationId
    if (!notificationId) return

    const notificationItem = this.findNotificationItem(notificationId)
    const collectiveId = notificationItem?.dataset.collectiveId

    // Disable button while loading
    button.disabled = true

    try {
      const response = await fetch("/notifications/actions/dismiss", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": getCsrfToken(),
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
        if (collectiveId) {
          const groupElement = this.element.querySelector(`[data-collective-group="${collectiveId}"]`)
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
          "X-CSRF-Token": getCsrfToken(),
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
        this.element.querySelectorAll("[data-collective-group]").forEach((item) => {
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

  async dismissForCollective(event: Event): Promise<void> {
    event.preventDefault()
    event.stopPropagation() // Prevent accordion toggle

    const button = event.currentTarget as HTMLButtonElement
    const collectiveId = button.dataset.collectiveId
    if (!collectiveId) return

    const originalText = button.textContent

    // Show loading state
    button.disabled = true
    button.textContent = "Dismissing..."

    try {
      const response = await fetch("/notifications/actions/dismiss_for_collective", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": getCsrfToken(),
          Accept: "application/json",
        },
        body: `collective_id=${encodeURIComponent(collectiveId)}`,
      })

      if (response.ok) {
        const data = (await response.json()) as { count?: number }
        const dismissedCount = data.count ?? 0

        // Remove all notification items in this collective group
        const groupElement = this.element.querySelector(`[data-collective-group="${collectiveId}"]`)
        if (groupElement) {
          groupElement.remove()
        }

        // Update unread count
        this.decrementUnreadCountBy(dismissedCount)

        // If no more groups, hide dismiss all button
        const remainingGroups = this.element.querySelectorAll("[data-collective-group]")
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

  async markRead(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const notificationId = button.dataset.notificationId
    if (!notificationId) return

    button.disabled = true

    try {
      const response = await fetch("/notifications/actions/mark_read", {
        method: "POST",
        headers: this.formHeaders(),
        body: `id=${encodeURIComponent(notificationId)}`,
      })

      if (response.ok) {
        const notificationItem = this.findNotificationItem(notificationId)
        if (notificationItem) {
          this.applyReadState(notificationItem)
        }
        this.decrementUnreadCount()
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

  markReadOnNavigate(event: Event): void {
    // No preventDefault — navigation proceeds; keepalive lets the request
    // complete after the page unloads.
    const link = event.currentTarget as HTMLElement
    const notificationId = link.dataset.notificationId
    if (!notificationId) return

    fetch("/notifications/actions/mark_read", {
      method: "POST",
      headers: this.formHeaders(),
      body: `id=${encodeURIComponent(notificationId)}`,
      keepalive: true,
    }).catch(() => {
      // Fire-and-forget: the inbox re-renders true state on next visit
    })

    // Update styling optimistically so a back-navigation shows the row as read
    const notificationItem = this.findNotificationItem(notificationId)
    if (notificationItem?.classList.contains("pulse-notification-unread")) {
      this.applyReadState(notificationItem)
      this.decrementUnreadCount()
    }
  }

  async markAllRead(event: Event): Promise<void> {
    event.preventDefault()

    const button = event.currentTarget as HTMLButtonElement
    const originalText = button.textContent

    button.disabled = true
    button.textContent = "Marking..."

    try {
      const response = await fetch("/notifications/actions/mark_all_read", {
        method: "POST",
        headers: this.formHeaders(),
      })

      if (response.ok) {
        this.element.querySelectorAll("[data-notification-item].pulse-notification-unread").forEach((item) => {
          this.applyReadState(item as HTMLElement)
        })
        this.setUnreadCount(0)
        button.style.display = "none"
        button.disabled = false
        button.textContent = originalText
        this.dispatchNotificationChange()
      } else {
        button.disabled = false
        button.textContent = originalText
      }
    } catch {
      button.disabled = false
      button.textContent = originalText
    }
  }

  async markReadForCollective(event: Event): Promise<void> {
    event.preventDefault()
    event.stopPropagation() // Prevent accordion toggle

    const button = event.currentTarget as HTMLButtonElement
    const collectiveId = button.dataset.collectiveId
    if (!collectiveId) return

    const originalText = button.textContent

    button.disabled = true
    button.textContent = "Marking..."

    try {
      const response = await fetch("/notifications/actions/mark_read_for_collective", {
        method: "POST",
        headers: this.formHeaders(),
        body: `collective_id=${encodeURIComponent(collectiveId)}`,
      })

      if (response.ok) {
        const data = (await response.json()) as { count?: number }

        this.element
          .querySelectorAll(`[data-notification-item][data-collective-id="${collectiveId}"].pulse-notification-unread`)
          .forEach((item) => {
            this.applyReadState(item as HTMLElement)
          })

        this.decrementUnreadCountBy(data.count ?? 0)
        button.disabled = false
        button.textContent = originalText
        this.dispatchNotificationChange()
      } else {
        button.disabled = false
        button.textContent = originalText
      }
    } catch {
      button.disabled = false
      button.textContent = originalText
    }
  }

  private applyReadState(item: HTMLElement): void {
    item.classList.remove("pulse-notification-unread")
    item.querySelector(".pulse-notification-indicator")?.remove()
    item.querySelector("[data-mark-read-button]")?.remove()
  }

  private formHeaders(): HeadersInit {
    return {
      "Content-Type": "application/x-www-form-urlencoded",
      "X-CSRF-Token": getCsrfToken(),
      Accept: "application/json",
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

    // Update the summary text. The strong element keeps its target attribute
    // so subsequent count updates can still find it.
    const summaryElement = this.element.querySelector("[data-notification-summary]")
    if (summaryElement) {
      if (count > 0) {
        summaryElement.innerHTML = `<strong data-notification-actions-target="unreadCount">${count}</strong> unread notifications`
      } else {
        summaryElement.textContent = "No unread notifications"
      }
    }

    if (count === 0) {
      // Nothing left to mark read
      if (this.hasMarkAllReadButtonTarget) {
        this.markAllReadButtonTarget.style.display = "none"
      }

      // Read rows can still be dismissed — only hide dismiss all once the
      // inbox is truly empty
      const itemsRemain = this.element.querySelector("[data-notification-item]") !== null
      if (!itemsRemain && this.hasDismissAllButtonTarget) {
        this.dismissAllButtonTarget.style.display = "none"
      }
    }
  }
}
