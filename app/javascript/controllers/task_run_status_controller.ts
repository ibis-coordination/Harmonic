import { Controller } from "@hotwired/stimulus"

/**
 * TaskRunStatusController polls for task run status changes and refreshes
 * the page when a running/queued task completes or new steps are available.
 *
 * Usage:
 * <div data-controller="task-run-status"
 *      data-task-run-status-url-value="/subagents/bot/runs/123"
 *      data-task-run-status-status-value="running"
 *      data-task-run-status-steps-count-value="0">
 * </div>
 */
export default class TaskRunStatusController extends Controller<HTMLElement> {
  static values = {
    url: String,
    status: String,
    stepsCount: { type: Number, default: 0 },
    pollInterval: { type: Number, default: 3000 },
  }

  declare urlValue: string
  declare statusValue: string
  declare stepsCountValue: number
  declare pollIntervalValue: number

  private pollTimer: number | null = null

  connect(): void {
    if (this.shouldPoll()) {
      // Check immediately on connect in case page loaded with stale data
      this.checkStatus()
      this.startPolling()
    }
  }

  disconnect(): void {
    this.stopPolling()
  }

  private shouldPoll(): boolean {
    return this.statusValue === "running" || this.statusValue === "queued"
  }

  private startPolling(): void {
    this.pollTimer = window.setInterval(() => {
      this.checkStatus()
    }, this.pollIntervalValue)
  }

  private stopPolling(): void {
    if (this.pollTimer !== null) {
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  private async checkStatus(): Promise<void> {
    try {
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "application/json",
        },
        credentials: "same-origin",
      })

      if (!response.ok) {
        return
      }

      const data = await response.json()

      // Reload if status changed or new steps are available
      const statusChanged = data.status !== this.statusValue
      const newSteps = (data.steps_count || 0) > this.stepsCountValue

      if (statusChanged || newSteps) {
        // Stop polling if task is done, otherwise continue polling
        const isDone = ["completed", "failed", "cancelled"].includes(data.status)
        if (isDone) {
          this.stopPolling()
        } else {
          // Update our local step count so we don't reload again for the same steps
          this.stepsCountValue = data.steps_count || 0
        }
        // Use cache-busting reload to ensure fresh page
        const url = new URL(window.location.href)
        url.searchParams.set("_t", Date.now().toString())
        window.location.href = url.toString()
      }
    } catch {
      // Silently fail - network errors shouldn't disrupt the user
    }
  }
}
