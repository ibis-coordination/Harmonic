import { Controller } from "@hotwired/stimulus"

/**
 * TaskRunStatusController polls for task run status changes and refreshes
 * the page when a running/queued task completes.
 *
 * Usage:
 * <div data-controller="task-run-status"
 *      data-task-run-status-url-value="/subagents/bot/runs/123"
 *      data-task-run-status-status-value="running">
 * </div>
 */
export default class TaskRunStatusController extends Controller<HTMLElement> {
  static values = {
    url: String,
    status: String,
    pollInterval: { type: Number, default: 3000 },
  }

  declare urlValue: string
  declare statusValue: string
  declare pollIntervalValue: number

  private pollTimer: number | null = null

  connect(): void {
    if (this.shouldPoll()) {
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

      if (data.status !== this.statusValue) {
        // Status changed - stop polling and refresh the page
        this.stopPolling()
        window.location.reload()
      }
    } catch {
      // Silently fail - network errors shouldn't disrupt the user
    }
  }
}
