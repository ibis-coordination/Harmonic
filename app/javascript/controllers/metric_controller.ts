import { Controller } from "@hotwired/stimulus"
import { getCsrfToken } from "../utils/csrf"

interface MetricResponse {
  metric_title: string
  metric_value: string
}

export default class MetricController extends Controller {
  static targets = ["valueDisplay"]
  static values = { url: String }

  declare readonly valueDisplayTarget: HTMLElement
  declare urlValue: string

  private refreshing = false

  initialize(): void {
    document.addEventListener("metricChange", this.refreshMetric.bind(this))
    document.addEventListener("decisionDataUpdated", this.refreshMetric.bind(this))
  }

  async refreshMetric(event: Event): Promise<void> {
    event.preventDefault()
    if (this.refreshing) return
    this.refreshing = true

    try {
      const response = await fetch(this.urlValue, {
        method: "GET",
        headers: {
          "X-CSRF-Token": getCsrfToken(),
        },
      })

      if (response.ok) {
        const json: MetricResponse = await response.json()
        ;(this.element as HTMLElement).title = json.metric_title
        this.valueDisplayTarget.textContent = json.metric_value
      } else {
        console.error("Error refreshing metric:", response)
      }
    } finally {
      this.refreshing = false
    }
  }
}
