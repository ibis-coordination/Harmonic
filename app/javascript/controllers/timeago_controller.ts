import { Controller } from "@hotwired/stimulus"
import { formatDistanceToNow } from "date-fns"

export default class TimeagoController extends Controller {
  static values = { datetime: String }

  declare datetimeValue: string

  private refreshInterval = 60 * 1000
  private refreshTimer: ReturnType<typeof setInterval> | null = null

  connect(): void {
    if (this.element.textContent === "...") {
      this.updateTime()
    }
    this.startRefreshing()
  }

  disconnect(): void {
    this.stopRefreshing()
  }

  updateTime(): void {
    const datetime = new Date(this.datetimeValue)
    const timeagoText = formatDistanceToNow(datetime, { addSuffix: true })
    this.element.innerHTML = `${timeagoText}`
  }

  startRefreshing(): void {
    if (this.refreshInterval) {
      this.refreshTimer = setInterval(() => {
        this.updateTime()
      }, this.refreshInterval)
    }
  }

  stopRefreshing(): void {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
    }
  }
}
